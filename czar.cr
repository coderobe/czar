#!/usr/bin/env crystal

require "binary_parser"
require "zlib"
require "xml"

def perror(msg : String)
  STDERR.write Slice.new (msg + "\n").to_unsafe, (msg + "\n").size
  exit 1
end

CHECKSUM_ALGO = {
  0 => :NONE,
  1 => :SHA1,
  2 => :MD5,
}

class XARHeader < BinaryParser
  endian :big
  string :magic, {count: 4}
  uint16 :header_size
  uint16 :version
  uint64 :length_compressed
  uint64 :length_uncompressed
  uint32 :checksum_algo
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

def xml_select(xml : XML::Node, node : String)
  perror "error in xml_select" if xml.nil?
  xml.children.select { |e| e.name == node }
end

def xml_value(xml : XML::Node, name : String)
  perror "error in xml_value" if xml.nil?
  xml.children.select { |e| e.name == name }.map { |e| e.content }
end

def xar_decode(entity : XML::Node, path : String = "./")
  entity_name = xml_value(entity, "name")
  if entity_name.size < 1
    puts "entity without name: #{entity.to_s}"
    return
  end
  entity_name = entity_name.first

  entity_type = xml_value(entity, "type")
  if entity_type.size < 1
    puts "entity without type: #{entity.to_s}"
    return
  end
  entity_type = entity_type.first

  puts "#{path}#{entity_name} (#{entity_type})"
  children = xml_select(entity, "file")
  if children.size > 0
    if entity_type != "directory"
      puts "warn: found a #{entity_type} with #{children.size} children"
    end

    children.each do |child|
      xar_decode child, "#{path}#{entity_name}/"
    end
  end
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
  puts "checksum algo #{CHECKSUM_ALGO[header.checksum_algo]}"

  toc_data = Bytes.new header.length_uncompressed
  file.seek header.header_size
  Zlib::Reader.open file do |zfile|
    zfile.read toc_data
  end

  xar = XML.parse SliceIO.new toc_data

  toc = xml_select(xar, "xar").first
  toc = xml_select(toc, "toc").first

  data_offset = header.header_size + header.length_compressed
  data_checksum = xml_select(toc, "checksum").first
  data_checksum_offset = xml_value(data_checksum, "offset").first.to_i
  data_checksum_size = xml_value(data_checksum, "size").first.to_i
  data_checksum_type = data_checksum["style"]

  puts "TOC is checksummed as #{data_checksum_type}, #{data_checksum_size} bytes stored at offset #{data_checksum_offset}"

  file.seek data_offset

  file.seek data_checksum_offset, IO::Seek::Current

  data_files = xml_select(toc, "file")
  puts "found #{data_files.size} files at the root"

  data_files.each do |entity|
    xar_decode entity
  end
end
