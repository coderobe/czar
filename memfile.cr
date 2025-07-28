# memory map crystal IO to C interop FILE*

@[Link("c")]
lib LibC
  alias FILE = Void

  {% if flag?(:darwin) %}
    fun funopen(
      cookie : Void*,
      readfn : (Void*, UInt8*, LibC::SizeT) -> LibC::SizeT,
      writefn : Void*,
      seekfn : (Void*, LibC::OffT, Int32) -> LibC::OffT,
      closefn : (Void*) -> Int32
    ) : FILE*
  {% else %}
    fun fopencookie(
      cookie : Void*,
      mode : LibC::Char*,
      ops : CookieIO
    ) : FILE*

    struct CookieIO
      read : (Void*, UInt8*, LibC::SizeT) -> LibC::SizeT
      write : Void*
      seek : (Void*, LibC::OffT, Int32) -> LibC::OffT
      close : (Void*) -> Int32
    end
  {% end %}
end

module MemFile
  class IOCookie
    getter io : IO

    def initialize(@io : IO)
    end
  end

  def self.from_io(io : IO) : Pointer(LibC::FILE)
    cookie = Box.box(IOCookie.new(io))

    read_cb = ->(cookie_ptr : Void*, buf : UInt8*, size : LibC::SizeT) : LibC::SizeT {
      wrapper = Box(IOCookie).unbox(cookie_ptr)
      begin
        bytes_read = wrapper.io.read(Slice.new(buf, size))
        bytes_read.to_u64
      rescue
        0.to_u64
      end
    }

    seek_cb = ->(cookie_ptr : Void*, offset : LibC::OffT, whence : Int32) : LibC::OffT {
      wrapper = Box(IOCookie).unbox(cookie_ptr)
      begin
        wrapper.io.seek(offset, IO::Seek.new(whence))
        wrapper.io.pos.to_i64
      rescue
        -1.to_i64
      end
    }

    close_cb = ->(cookie_ptr : Void*) : Int32 {
      Box(IOCookie).unbox(cookie_ptr) # let GC handle it
      0
    }

    {% if flag?(:darwin) %}
      LibC.funopen(
        cookie.as(Void*),
        read_cb,
        Pointer(Void).null,
        seek_cb,
        close_cb
      )
    {% else %}
      ops = LibC::CookieIO.new(
        read: read_cb,
        write: Pointer(Void).null,
        seek: seek_cb,
        close: close_cb
      )
      LibC.fopencookie(cookie.as(Void*), "r".to_unsafe, ops)
    {% end %}
  end
end
