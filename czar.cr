#!/usr/bin/env crystal

require "binary_parser"
require "zlib"
require "xml"

def perror(msg : String)
  STDERR.write Slice.new (msg + "\n").to_unsafe, (msg + "\n").size
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

class SliceIO < IO
  def initialize(@slice : Bytes)
  end

  def read(slice : Bytes)
    slice.size.times { |i| slice[i] = @slice[i] }
    @slice += slice.size
    slice.size
  end

  def write(slice : Bytes)
    slice.size.times { |i| @slice[i] = slice[i] }
    @slice += slice.size
    nil
  end

  def to_slice
    @slice
  end
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

def xar_decode_data(entity : XML::Node, data : XARFileData = XARFileData.new)
  data.offset = (xml_value(entity, "offset").first rescue 0).to_u64
  data.size = (xml_value(entity, "size").first rescue 0).to_u64
  data.length = (xml_value(entity, "length").first rescue 0).to_u64
  data.checksum_extracted = xml_value(entity, "extracted-checksum").first rescue ""
  data.checksum_extracted_style = XARChecksumAlgo.parse(xml_select(entity, "extracted-checksum").first["style"]) rescue XARChecksumAlgo::NONE
  data.checksum_archived = xml_value(entity, "archived-checksum").first rescue ""
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
  unless data.size < 1
    xar_decode_data data.first, file.data
  end

  ea = xml_select(entity, "ea")
  unless ea.size < 1
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

File.open "test.xar", "r" do |file|
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
  Zlib::Reader.open file do |zfile|
    zfile.read toc_data
  end

  xar_xml = XML.parse SliceIO.new toc_data
  toc = xml_select(xml_select(xar_xml, "xar").first, "toc").first

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

  puts "#{xar.files.select { |e| e.type == XARFileType::FILE }.size} files"
  puts "#{xar.files.select { |e| e.type == XARFileType::DIRECTORY }.size} directories"
end
