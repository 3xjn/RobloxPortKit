local Base64={}
local alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local values={};for i=1,#alphabet do values[alphabet:sub(i,i)]=i-1 end
function Base64.isValid(input)
    return type(input)=='string'and #input%4==0 and not input:find('[^%w+/=]')
        and not input:sub(1,-3):find('=',1,true)and not(input:sub(-2,-2)=='='and input:sub(-1)~='=')
end
function Base64.encode(input)
    if typeof(input)=='buffer'then input=buffer.tostring(input)end
    local result={}
    for i=1,#input,3 do
        local a,b,c=input:byte(i,i+2);local n=a*65536+(b or 0)*256+(c or 0)
        local x=math.floor(n/262144)%64;local y=math.floor(n/4096)%64;local z=math.floor(n/64)%64;local w=n%64
        result[#result+1]=alphabet:sub(x+1,x+1)..alphabet:sub(y+1,y+1)..(b and alphabet:sub(z+1,z+1)or '=')..(c and alphabet:sub(w+1,w+1)or '=')
    end
    return table.concat(result)
end
function Base64.decode(input)
    assert(Base64.isValid(input),'Invalid base64 payload')
    local result={}
    for i=1,#input,4 do
        local a,b,c,d=input:sub(i,i),input:sub(i+1,i+1),input:sub(i+2,i+2),input:sub(i+3,i+3)
        local n=assert(values[a])*262144+assert(values[b])*4096+(values[c]or 0)*64+(values[d]or 0)
        result[#result+1]=string.char(math.floor(n/65536)%256)..(c~='='and string.char(math.floor(n/256)%256)or '')..(d~='='and string.char(n%256)or '')
    end
    return table.concat(result)
end
return Base64
