#!/usr/bin/env crystal
require "binary_parser"
require "compress/zlib"
require "compress/gzip"
require "xml"
require "digest/md5"
require "digest/sha1"

require "./sliceio"
require "./bzip2"

def perror(msg : String)
  STDERR.write Slice.new((msg + "\n").to_unsafe, (msg + "\n").size)
  exit 1
end

def xml_select(xml : XML::Node, node : String)
  perror "error in xml_select" if xml.nil?
  xml.children.select { |e| e.name == node }
end

def xml_value(xml : XML::Node, name : String)
  perror "error in xml_value" if xml.nil?
  xml.children.select { |e| e.name == name }.map { |e| e.content }
end

enum XARChecksumAlgo
  NONE
  SHA1
  MD5
end

enum XARFileType
  FILE
  DIRECTORY
end

enum XARFileEncoding
  NONE
  GZIP
  BZIP2
end

class XARHeader < BinaryParser
  endian :big
  string :magic, {count: 4}
  uint16 :header_size
  uint16 :version
  uint64 :length_compressed
  uint64 :length_uncompressed
  uint32 :checksum_algo
end

class XARFileData
  property offset : UInt64 = 0
  property size : UInt64 = 0
  property length : UInt64 = 0
  property checksum_extracted : String = ""
  property checksum_extracted_style : XARChecksumAlgo = XARChecksumAlgo::NONE
  property checksum_archived : String = ""
  property checksum_archived_style : XARChecksumAlgo = XARChecksumAlgo::NONE
  property encoding : XARFileEncoding = XARFileEncoding::NONE
end

class XARFileEAttrs < XARFileData
  property name : String = ""
end

class XARChecksum
  property style : XARChecksumAlgo = XARChecksumAlgo::NONE
  property size : UInt64 = 0
  property offset : UInt64 = 0
end

class XARFile
  property path : String = ""
  property name : String = ""
  property type : XARFileType = XARFileType::FILE
  property mode : Array(UInt8) = [0_u8, 0_u8, 0_u8, 0_u8]
  property uid : UInt64 = 0
  property gid : UInt64 = 0
  property user : String = ""
  property group : String = ""
  property size : UInt64 = 0
  property data : XARFileData = XARFileData.new
  property ea : XARFileEAttrs = XARFileEAttrs.new
end

class XAR
  property checksum : XARChecksum = XARChecksum.new
  property files : Array(XARFile) = [] of XARFile
end

def calculate_checksum(data : Bytes, algo : XARChecksumAlgo) : String
  case algo
  when XARChecksumAlgo::MD5
    Digest::MD5.hexdigest(data)
  when XARChecksumAlgo::SHA1
    Digest::SHA1.hexdigest(data)
  else
    ""
  end
end

def validate_checksum(data : Bytes, expected : String, algo : XARChecksumAlgo, description : String) : Bool
  return true if algo == XARChecksumAlgo::NONE || expected.empty?

  calculated = calculate_checksum(data, algo)
  if calculated.downcase == expected.downcase
    puts "✓ #{description} checksum valid (#{algo})"
    return true
  else
    puts "✗ #{description} checksum INVALID!"
    puts "  Expected: #{expected.downcase}"
    puts "  Calculated: #{calculated.downcase}"
    return false
  end
end

def normalize_checksum(checksum_str : String) : String
  return "" if checksum_str.empty?
  checksum_str.downcase
end

def detect_compression_format(data : Bytes) : XARFileEncoding
  return XARFileEncoding::NONE if data.size < 2

  # Check for GZIP magic bytes (1f 8b)
  if data[0] == 0x1f && data[1] == 0x8b
    return XARFileEncoding::GZIP
  end

  # Check for BZIP2 magic bytes (42 5a = "BZ")
  if data[0] == 0x42 && data[1] == 0x5a
    return XARFileEncoding::BZIP2
  end

  # Check for ZLIB magic bytes (78 da, 78 9c, 78 01, etc.)
  if data[0] == 0x78
    return XARFileEncoding::GZIP # Treat ZLIB as GZIP-compatible
  end

  return XARFileEncoding::NONE
end

def xar_decode_data(entity : XML::Node, data : XARFileData = XARFileData.new)
  data.offset = (xml_value(entity, "offset").first rescue 0).to_u64
  data.size = (xml_value(entity, "size").first rescue 0).to_u64
  data.length = (xml_value(entity, "length").first rescue 0).to_u64
  data.checksum_extracted = normalize_checksum((xml_value(entity, "extracted-checksum").first rescue ""))
  data.checksum_extracted_style = XARChecksumAlgo.parse(xml_select(entity, "extracted-checksum").first["style"]) rescue XARChecksumAlgo::NONE
  data.checksum_archived = normalize_checksum((xml_value(entity, "archived-checksum").first rescue ""))
  data.checksum_archived_style = XARChecksumAlgo.parse(xml_select(entity, "archived-checksum").first["style"]) rescue XARChecksumAlgo::NONE
  data.encoding = XARFileEncoding.parse(xml_select(entity, "encoding").first["style"].split("/x-").last) rescue XARFileEncoding::NONE
  data
end

def xar_decode_ea(entity : XML::Node, ea : XARFileEAttrs = XARFileEAttrs.new)
  xar_decode_data entity, ea
  ea.name = xml_value(entity, "name").first rescue ""
  ea
end

def xar_decode_file(entity : XML::Node, path : String = "./")
  file = XARFile.new
  file.path = path
  file.name = xml_value(entity, "name").first rescue ""
  file.type = XARFileType.parse(xml_value(entity, "type").first) rescue XARFileType::FILE
  file.mode = (xml_value(entity, "mode").first rescue "0000").split("").map { |p| p.to_u8 }
  file.uid = (xml_value(entity, "uid").first rescue 0).to_u64
  file.gid = (xml_value(entity, "gid").first rescue 0).to_u64
  file.user = xml_value(entity, "user").first rescue ""
  file.group = xml_value(entity, "group").first rescue ""
  file.size = (xml_value(entity, "size").first rescue 0).to_u64

  data = xml_select(entity, "data")
  unless data.empty?
    xar_decode_data data.first, file.data
  end
  ea = xml_select(entity, "ea")
  unless ea.empty?
    xar_decode_ea ea.first, file.ea
  end
  files = [file]
  children = xml_select(entity, "file")
  if children.size > 0
    if file.type != XARFileType::DIRECTORY
      puts "warn: found a #{file.type} with #{children.size} children"
    end
    children.each do |child|
      files += xar_decode_file child, "#{path}#{file.name}/"
    end
  end
  files
end

# Parse command line options
strict_mode = false
no_extract = false
filename = ""

i = 0
while i < ARGV.size
  case ARGV[i]
  when "--strict"
    strict_mode = true
  when "--no-extract"
    no_extract = true
  when "--help", "-h"
    puts "Usage: #{PROGRAM_NAME} [options] <xar_file>"
    puts "Options:"
    puts "  --strict      Fail extraction if any checksum validation fails"
    puts "  --no-extract  Only validate checksums, don't extract files"
    puts "  --help, -h    Show this help message"
    exit 0
  else
    if filename.empty?
      filename = ARGV[i]
    else
      perror "multiple filenames provided"
    end
  end
  i += 1
end

perror "no filename given" if filename.empty?

File.open(filename, "r") do |file|
  header = XARHeader.new
  header.load file

  perror "not a xar file" if header.magic != "xar!"

  puts "#{header.magic}"
  puts "header size #{header.header_size}"
  puts "format version #{header.version}"
  puts "TOC length (compressed) #{header.length_compressed}"
  puts "TOC length (uncompressed) #{header.length_uncompressed}"
  puts "checksum algo #{XARChecksumAlgo.new(header.checksum_algo.to_i32).to_s}"

  toc_data = Bytes.new header.length_uncompressed
  file.seek header.header_size

  Compress::Zlib::Reader.open file do |zfile|
    zfile.read toc_data
  end

  xar_xml = XML.parse String.new(toc_data)
  xar_obj = xml_select(xar_xml, "xar")
  perror "empty xar object" if xar_obj.empty?

  tocs = xml_select(xar_obj.first, "toc")
  perror "empty TOC" if tocs.empty?

  toc = tocs.first
  puts "reading TOC"

  xar = XAR.new
  elem = xml_select(toc, "checksum").first
  xar.checksum.style = XARChecksumAlgo.parse elem["style"]
  xar.checksum.size = xml_value(elem, "size").first.to_u64
  xar.checksum.offset = xml_value(elem, "offset").first.to_u64
  puts "TOC is checksummed as #{xar.checksum.style}, #{xar.checksum.size} bytes at offset #{xar.checksum.offset}"


  xml_select(toc, "file").each do |entity|
    xar.files += xar_decode_file entity
  end

  puts "contains #{xar.files.select { |e| e.type == XARFileType::FILE }.size} files across #{xar.files.select { |e| e.type == XARFileType::DIRECTORY }.size} directories"
  puts xar.files.map { |e| "#{e.path}#{e.name}" }.join " "

  # Get heap offset
  heap_start = header.header_size.to_u64 + header.length_compressed
  file.seek(0, IO::Seek::End)
  file_size = file.tell
  file.seek(0)
  heap_size = file_size - heap_start

  file.seek heap_start
  heap_data = Bytes.new(heap_size)
  file.read(heap_data)


  # Unarchive files (or just validate if --no-extract is specified)
  validation_results = {
    "files_processed"             => 0,
    "files_extracted"             => 0,
    "checksum_failures"           => 0,
    "archived_checksum_failures"  => 0,
    "extracted_checksum_failures" => 0,
  }

  xar.files.each do |xarfile|
    next if xarfile.type == XARFileType::DIRECTORY

    output_path = File.join("#{filename}.extracted", xarfile.path, xarfile.name)
    Dir.mkdir_p(File.dirname(output_path)) unless File.exists?(File.dirname(output_path))

    # Log file metadata
    puts "Processing file: #{output_path}"
    puts "  Offset: #{xarfile.data.offset}"
    puts "  Compressed size: #{xarfile.data.length}"
    puts "  Uncompressed size: #{xarfile.data.size}"
    puts "  Encoding: #{xarfile.data.encoding}"

    # Extract compressed data from heap
    # In XAR format: length = compressed size, size = uncompressed size
    compressed_size = xarfile.data.length
    if xarfile.data.offset + compressed_size > heap_data.size
      puts "  Error: Requested data extends beyond heap boundary (offset: #{xarfile.data.offset}, compressed_size: #{compressed_size}, heap_size: #{heap_data.size})"
      next
    end

    compressed_data = heap_data[xarfile.data.offset, compressed_size]

    validation_results["files_processed"] += 1

    # Validate archived checksum (on compressed data)
    archived_valid = validate_checksum(compressed_data, xarfile.data.checksum_archived,
      xarfile.data.checksum_archived_style,
      "archived data for #{xarfile.name}")

    # Auto-detect compression format based on magic bytes
    actual_encoding = detect_compression_format(compressed_data)

    # Decompress the data if necessary
    decompressed_data = case actual_encoding
                        when XARFileEncoding::GZIP
                          begin
                            # Check if it's actually ZLIB
                            is_zlib = compressed_data[0] == 0x78
                            if is_zlib
                              Compress::Zlib::Reader.new(SliceIO.new(compressed_data)).getb_to_end
                            else
                              Compress::Gzip::Reader.new(SliceIO.new(compressed_data)).getb_to_end
                            end
                          rescue e
                            puts "Error decompressing #{is_zlib ? "ZLIB" : "GZIP"} data for #{xarfile.name}: #{e}"
                            next
                          end
                        when XARFileEncoding::BZIP2
                          begin
                            Bzip2::Reader.new(SliceIO.new(compressed_data)).getb_to_end
                          rescue e
                            puts "Error decompressing BZIP2 data for #{xarfile.name}: #{e}"
                            next
                          end
                        else
                          compressed_data
                        end

    # Validate extracted checksum (on decompressed data)
    extracted_valid = validate_checksum(decompressed_data, xarfile.data.checksum_extracted,
      xarfile.data.checksum_extracted_style,
      "extracted data for #{xarfile.name}")

    # Track validation results
    unless archived_valid
      validation_results["archived_checksum_failures"] += 1
    end
    unless extracted_valid
      validation_results["extracted_checksum_failures"] += 1
    end

    # Handle checksum validation results
    checksum_failed = !archived_valid || !extracted_valid
    if checksum_failed
      validation_results["checksum_failures"] += 1
    end

    if checksum_failed && strict_mode
      perror "Checksum validation failed for #{output_path} (strict mode enabled)"
    elsif checksum_failed
      puts "Warning: Checksum validation failed for #{output_path}, extracting anyway"
    end

    # Write the file (unless --no-extract is specified)
    if no_extract
      puts "Validated: #{output_path} (not extracted)"
    else
      begin
        File.write(output_path, decompressed_data)
        puts "Extracted: #{output_path}"
        validation_results["files_extracted"] += 1
      rescue e
        perror "Error writing file #{output_path}: #{e}"
      end
    end
  end

  # Print validation summary
  puts "\n=== #{no_extract ? "Validation" : "Extraction"} Summary ==="
  puts "Files processed: #{validation_results["files_processed"]}"
  puts "Files extracted: #{validation_results["files_extracted"]}" unless no_extract
  puts "Checksum failures: #{validation_results["checksum_failures"]}"
  puts "  - Archived checksum failures: #{validation_results["archived_checksum_failures"]}"
  puts "  - Extracted checksum failures: #{validation_results["extracted_checksum_failures"]}"

  if validation_results["checksum_failures"] > 0
    puts "\nWarning: Some checksum validations failed. The extracted files may be corrupted."
  else
    puts "\n✓ All checksums validated successfully!"
  end
end
