local Benchmark = {}
Benchmark.__index = Benchmark

function Benchmark.new(capacity)
	return setmetatable({capacity = capacity or 1200, costs = {}, intervals = {}, count = 0}, Benchmark)
end

function Benchmark:record(seconds, interval)
	self.count += 1
	local i = (self.count - 1) % self.capacity + 1
	self.costs[i] = seconds * 1000
	self.intervals[i] = interval or 0
end

function Benchmark:stats()
	local values = table.clone(self.costs)
	table.sort(values)
	local total, intervals = 0, 0
	for _, v in values do total += v end
	for _, v in self.intervals do intervals += v end
	local n = #values
	return {samples = n, meanMs = if n > 0 then total / n else 0,
		p50Ms = values[math.max(1, math.ceil(n * .50))] or 0,
		p95Ms = values[math.max(1, math.ceil(n * .95))] or 0,
		maxMs = values[n] or 0, observedRenderFPS = if intervals > 0 then n / intervals else 0,
		scope = "frame callback CPU only; excludes GPU and loading"}
end

-- Transform source BEFORE installing it in Studio; running bytecode cannot be changed.
function Benchmark.stripNative(source)
	return ("\n" .. source):gsub("\n[ \t]*%-%-!native[^\n]*", ""):sub(2)
end

return Benchmark
