class SliceIO < IO
  def initialize(@slice : Bytes)
  end

  def read(slice : Bytes)
    n = [slice.size, @slice.size].min
    n.times do |i|
      slice[i] = @slice[i]
    end
    @slice = @slice[n..-1]
    n
  end

  def write(slice : Bytes) : Nil
    raise "Write not implemented"
  end
end
