local Players = game:GetService("Players")

local Cursor = require(script.Parent.Packages.Cursor)
type Cursor = typeof(Cursor.new())

type Descriptor<T = any> = {
	read: (cursor: Cursor) -> T,
	write: (cursor: Cursor, value: T) -> (),
}

local function makeTypeDescriptor<T>(
	read: index<Descriptor<T>, "read">,
	write: index<Descriptor<T>, "write">
): Descriptor<T>
	return { read = read, write = write }
end

local function makeCursorTypeDescriptor<T>(name: string): Descriptor<T>
	return { read = (Cursor :: any)[`read{name}`], write = (Cursor :: any)[`write{name}`] }
end

local I16Limit = 32767

local VECTOR_DEFAULT = 0
local VECTOR_UNITED = 1
local VECTOR_ZERO = 2
local CFRAME_DEFAULT = 0
local CFRAME_ALIGNED = 1
local CFRAME_ZERO = 2

local descriptors = {
	U8 = makeCursorTypeDescriptor("U8"),
	U16 = makeCursorTypeDescriptor("U16"),
	U32 = makeCursorTypeDescriptor("U32"),
	I8 = makeCursorTypeDescriptor("I8"),
	I16 = makeCursorTypeDescriptor("I16"),
	I32 = makeCursorTypeDescriptor("I32"),
	F32 = makeCursorTypeDescriptor("F32"),
	F64 = makeCursorTypeDescriptor("F64"),
	Bool = makeCursorTypeDescriptor("Bool"),
	Buffer = makeCursorTypeDescriptor("Buffer"),
	String = makeCursorTypeDescriptor("String"),
	Any = makeCursorTypeDescriptor("Any"),

	Player = makeTypeDescriptor(function(cursor): Player
		return Players:GetPlayerByUserId(cursor:readF64()) :: Player
	end, function(cursor, player: Player)
		cursor:writeF64(player.UserId)
	end),

	Vector2 = makeTypeDescriptor(function(cursor): Vector2
		local kind = cursor:readU8()

		if kind == VECTOR_DEFAULT then
			return Vector2.new(cursor:readF32(), cursor:readF32())
		elseif kind == VECTOR_UNITED then
			return Vector2.new(cursor:readI16() / I16Limit, cursor:readI16() / I16Limit)
		elseif kind == VECTOR_ZERO then
			return Vector2.zero
		end

		return Vector2.zero
	end, function(cursor, vec: Vector2)
		if vec.Magnitude == 1 then
			cursor:writeU8(VECTOR_DEFAULT)
			cursor:writeF32(vec.X)
			cursor:writeF32(vec.Y)
		elseif vec.Unit == vec then
			cursor:writeU8(VECTOR_UNITED)
			cursor:writeI16(math.round(vec.X * I16Limit))
			cursor:writeI16(math.round(vec.Y * I16Limit))
		else
			cursor:writeU8(VECTOR_ZERO)
		end
	end),
	Vector3 = makeTypeDescriptor(function(cursor): Vector3
		local kind = cursor:readU8()

		if kind == VECTOR_DEFAULT then
			return Vector3.new(cursor:readF32(), cursor:readF32(), cursor:readF32())
		elseif kind == VECTOR_UNITED then
			return Vector3.new(cursor:readI16() / I16Limit, cursor:readI16() / I16Limit, cursor:readI16() / I16Limit)
		elseif kind == VECTOR_ZERO then
			return Vector3.zero
		end

		return Vector3.zero
	end, function(cursor, vec: Vector3)
		if vec.Magnitude == 1 then
			cursor:writeU8(VECTOR_DEFAULT)
			cursor:writeF32(vec.X)
			cursor:writeF32(vec.Y)
			cursor:writeF32(vec.Z)
		elseif vec.Unit == vec then
			cursor:writeU8(VECTOR_UNITED)
			cursor:writeI16(math.round(vec.X * I16Limit))
			cursor:writeI16(math.round(vec.Y * I16Limit))
			cursor:writeI16(math.round(vec.Z * I16Limit))
		else
			cursor:writeU8(VECTOR_ZERO)
		end
	end),
	CFrame = makeTypeDescriptor(function(cursor): CFrame
		local kind = cursor:readU8()

		if kind == CFRAME_DEFAULT then
			local origin = Vector3.new(cursor:readF32(), cursor:readF32(), cursor:readF32())
			local look = origin
				+ Vector3.new(cursor:readI16() / I16Limit, cursor:readI16() / I16Limit, cursor:readI16() / I16Limit)

			return CFrame.new(origin, look)
		elseif kind == CFRAME_ALIGNED then
			return CFrame.new(cursor:readF32(), cursor:readF32(), cursor:readF32())
		elseif kind == CFRAME_ZERO then
			return CFrame.new()
		end

		return CFrame.new()
	end, function(cursor, cf: CFrame)
		if cf == CFrame.new() then
			cursor:writeU8(CFRAME_ZERO)
		elseif cf.LookVector ~= Vector3.zAxis * -1 then
			cursor:writeU8(CFRAME_DEFAULT)
			cursor:writeF32(cf.Position.X)
			cursor:writeF32(cf.Position.Y)
			cursor:writeF32(cf.Position.Z)
			cursor:writeI16(math.round(cf.LookVector.X * I16Limit))
			cursor:writeI16(math.round(cf.LookVector.Y * I16Limit))
			cursor:writeI16(math.round(cf.LookVector.Z * I16Limit))
		else
			cursor:writeU8(CFRAME_ALIGNED)
			cursor:writeF32(cf.Position.X)
			cursor:writeF32(cf.Position.Y)
			cursor:writeF32(cf.Position.Z)
		end
	end),
}

local types = {
	U8 = ("U8" :: any) :: number,
	U16 = ("U16" :: any) :: number,
	U32 = ("U32" :: any) :: number,
	I8 = ("I8" :: any) :: number,
	I16 = ("I16" :: any) :: number,
	I32 = ("I32" :: any) :: number,
	F32 = ("F32" :: any) :: number,
	F64 = ("F64" :: any) :: number,
	Bool = ("Bool" :: any) :: boolean,
	Buffer = ("Buffer" :: any) :: buffer,
	String = ("String" :: any) :: string,
	Any = ("Any" :: any) :: any,

	Player = ("Player" :: any) :: Player,
	Vector2 = ("Vector2" :: any) :: Vector2,
	Vector3 = ("Vector3" :: any) :: Vector3,
	CFrame = ("CFrame" :: any) :: CFrame,

	Struct = function<T>(schema: T): T
		local fields: { { name: string, typeKey: string } } = {}
		for name, typeKey in schema :: { [string]: string } do
			table.insert(fields, { name = name, typeKey = typeKey })
		end

		table.sort(fields, function(a, b)
			for i = 1, math.min(#a.name, #b.name) do
				local ba, bb = string.byte(a.name, i), string.byte(b.name, i)
				if ba ~= bb then
					return ba < bb
				end
			end
			return #a.name < #b.name
		end)

		local key = "struct@"
		for _, field in fields do
			key ..= `{field.name}:{field.typeKey},`
		end

		if descriptors[key] then
			return key
		end

		descriptors[key] = makeTypeDescriptor(function(cursor): T
			local result = {}
			for _, field in fields do
				result[field.name] = descriptors[field.typeKey].read(cursor)
			end
			return result
		end, function(cursor, value: { [any]: any })
			for _, field in fields do
				descriptors[field.typeKey].write(cursor, value[field.name])
			end
		end)

		return key
	end,
	Array = function<T>(inner: T): { T }
		local key = `array@{inner}`
		if descriptors[key] then
			return key :: any
		end

		local innerDesc = descriptors[inner]
		descriptors[key] = makeTypeDescriptor(function(cursor): T
			local len = cursor:readU16()
			local result = table.create(len)
			for i = 1, len do
				result[i] = innerDesc.read(cursor)
			end
			return result
		end, function(cursor, value: { T })
			cursor:writeU16(#value)
			for _, item in value do
				innerDesc.write(cursor, item)
			end
		end)

		return key :: any
	end,
	Optional = function<T>(inner: T): T?
		local key = `optional@{inner}`
		if descriptors[key] then
			return key :: any
		end

		local innerDesc = descriptors[inner]
		descriptors[key] = makeTypeDescriptor(function(cursor): T
			if cursor:readBool() then
				return innerDesc.read(cursor) :: T
			end
			return nil
		end, function(cursor, value: T?)
			local present = value ~= nil
			cursor:writeBool(present)
			if present then
				innerDesc.write(cursor, value)
			end
		end)

		return key :: any
	end,
}

return {
	Descriptors = descriptors,
	Types = types,
}
