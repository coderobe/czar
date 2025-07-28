require "./memfile"

@[Link("bzip2")]
lib LibBzip2
  alias BZFILE = Void

  fun BZ2_bzReadOpen(bzerror : Pointer(Int32), f : Pointer(Void), verbosity : Int32, small : Int32, unused : Pointer(Void), nUnused : Int32) : Pointer(BZFILE)
  fun BZ2_bzRead(bzerror : Pointer(Int32), b : Pointer(BZFILE), buf : Pointer(UInt8), len : Int32) : Int32
  fun BZ2_bzReadClose(bzerror : Pointer(Int32), b : Pointer(BZFILE)) : Void
end

class Bzip2::Reader
  @io : IO
  @bzfile : Pointer(LibBzip2::BZFILE)
  @bzerror : Pointer(Int32)
  @file_ptr : Pointer(Void) # MemFile pointer

  def initialize(io : IO)
    @io = io

    # Create a memory-backed FILE* pointer from IO
    @file_ptr = MemFile.from_io(io)
    raise "Could not map memfile" unless @file_ptr

    @bzerror = Pointer(Int32).malloc(1)
    @bzfile = LibBzip2.BZ2_bzReadOpen(@bzerror, @file_ptr, 0, 0, Pointer(Void).null, 0)
    raise "Failed to open Bzip2 stream, error=#{@bzerror.value}" unless @bzfile
  end

  def getb_to_end : Bytes
    result = Bytes.new(0)
    buffer = Bytes.new(4096)

    while true
      bytes_read = LibBzip2.BZ2_bzRead(@bzerror, @bzfile, buffer.to_unsafe, buffer.size)
      case @bzerror.value
      when 0  # BZ_OK
        result += buffer[0, bytes_read]
      when 4  # BZ_STREAM_END
        result += buffer[0, bytes_read] if bytes_read > 0
        break
      else
        raise "BZ2_bzRead failed with error #{@bzerror.value}"
      end
    end

    result
  end

  def finalize
    LibBzip2.BZ2_bzReadClose(@bzerror, @bzfile)
  end
end
