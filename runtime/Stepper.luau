local Stepper = {}
Stepper.__index = Stepper

local function finite(value)
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

function Stepper.new(config)
	config = config or {}
	local rate = config.rate or 60
	local maxDelta = config.maxDelta or .25
	local maxSteps = config.maxStepsPerFrame or config.maxSteps or 8
	assert(finite(rate) and rate > 0, "Invalid step rate")
	assert(finite(maxDelta) and maxDelta > 0, "Invalid maximum delta")
	assert(finite(maxSteps) and maxSteps >= 1 and maxSteps % 1 == 0, "Invalid maximum steps")
	local self = setmetatable({stepDt = 1 / rate, maxDelta = maxDelta,
		maxStepsPerFrame = maxSteps, accumulator = 0, speed = 1}, Stepper)
	self:setSpeed(config.speed or 1)
	return self
end

function Stepper:setSpeed(speed)
	assert(finite(speed) and speed >= 0, "Invalid step speed")
	self.speed = speed
end

function Stepper:advance(dt)
	assert(finite(dt) and dt >= 0, "Invalid frame delta")
	if self.speed == 0 then return 0, self.accumulator / self.stepDt end
	-- Clamp wall time before speeding up simulation. Drop excess whole ticks so
	-- a stalled frame cannot leave a backlog; retain the interpolation fraction.
	self.accumulator += math.min(dt, self.maxDelta) * self.speed
	local available = math.floor(self.accumulator / self.stepDt + 1e-9)
	local steps = math.min(available, math.ceil(self.maxStepsPerFrame * self.speed))
	self.accumulator = math.max(0, self.accumulator - available * self.stepDt)
	return steps, self.accumulator / self.stepDt
end

return Stepper
