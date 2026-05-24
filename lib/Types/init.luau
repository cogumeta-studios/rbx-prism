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
		end, function(cursor, value: { T })
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
