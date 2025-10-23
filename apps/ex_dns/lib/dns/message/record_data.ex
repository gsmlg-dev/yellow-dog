defprotocol DNS.Message.RecordData do
  @spec to_iodata(term()) :: binary()
  def to_iodata(value)
end
