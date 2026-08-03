--!strict

export type ScalarSpring = {
	Position: number,
	Velocity: number,
}

local Spring = {}

function Spring.new(initialPosition: number): ScalarSpring
	return {
		Position = initialPosition,
		Velocity = 0,
	}
end

function Spring.reset(spring: ScalarSpring, position: number)
	spring.Position = position
	spring.Velocity = 0
end

function Spring.step(spring: ScalarSpring, target: number, frequency: number, deltaTime: number): number
	local angularFrequency = math.max(0.001, frequency) * math.pi * 2
	local displacement = spring.Position - target
	local decay = math.exp(-angularFrequency * deltaTime)
	local integration = (spring.Velocity + angularFrequency * displacement) * deltaTime

	spring.Position = target + (displacement + integration) * decay
	spring.Velocity = (spring.Velocity - angularFrequency * integration) * decay
	return spring.Position
end

return Spring
