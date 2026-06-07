return function(limit: number, perSecs: number?)
	local buckets = setmetatable({}, { __mode = "k" })

	local refillRate = limit / (perSecs or 1)

	return function(ctx, next)
		if ctx.Stage ~= "Incoming" then
			return next()
		end

		local key = ctx.Player or "global"

		local now = os.clock()

		local bucket = buckets[key]

		if not bucket then
			bucket = {
				Tokens = limit,
				LastRefill = now,
			}

			buckets[key] = bucket
		end

		local elapsed = now - bucket.LastRefill
		bucket.LastRefill = now

		bucket.Tokens = math.min(limit, bucket.Tokens + elapsed * refillRate)

		if bucket.Tokens < 1 then
			return
		end

		bucket.Tokens -= 1

		next()
	end
end
