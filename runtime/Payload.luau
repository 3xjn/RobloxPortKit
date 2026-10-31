--!optimize 2
-- Native decoding keeps asset decompression out of the Luau frame budget.
local Payload={}
function Payload.decode(encoded,entry,legacy,service)
    service=service or game:GetService('EncodingService')
    local data=service:Base64Decode(buffer.fromstring(encoded))
    if entry.compression=='zstd'then
        local algorithm=Enum.CompressionAlgorithm.Zstd
        assert(service:GetDecompressedBufferSize(data,algorithm)==entry.bytes,'Payload size metadata mismatch')
        data=service:DecompressBuffer(data,algorithm)
    else
        assert(not entry.compression or entry.compression=='zlib','Unsupported payload compression')
        data=assert(legacy,'Legacy zlib decoder is required')(data,entry.bytes)
    end
    assert(buffer.len(data)==entry.bytes,'Decoded payload size mismatch')
    return data
end
return Payload
