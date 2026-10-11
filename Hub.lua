local DuntUI
local duntOk, duntErr = pcall(function()
    DuntUI = loadstring(game:HttpGet("https://raw.githubusercontent.com/DuntSunrise/DuntLibrary/refs/heads/main/DuntUI.lua"))()
end)
if not duntOk or not DuntUI then
    warn("[KvantScript] DuntUI failed to load:", duntErr)
    return
end

do
	local rs = game:GetService("ReplicatedStorage")
	local players = game:GetService("Players")
	local collection = game:GetService("CollectionService")
	local run = game:GetService("RunService")
	local lp = players.LocalPlayer

	local stats = game:GetService("Stats")

	getgenv().SILENT_S = {
		enabled = false,
		predict = true,
		force = false,
		auto_on = false,
		auto_delay = 0,
		am_sheriff = false,
		fire_gap = 0,
		last_shot = 0,
		stand_off = 15,
	}
	local S = getgenv().SILENT_S

	local MAX_RANGE = 300

	local gap_min = 0
	local gap_seen = false
	local gap_gun = nil
	local want_since = 0

	local function gap_reset()
		gap_min = 0
		gap_seen = false
		S.fire_gap = 0
	end

	local function gap_push(value)
		if value <= 0 then return end
		if not gap_seen or value < gap_min then
			gap_min = value
			gap_seen = true
			S.fire_gap = value
		end
	end

	local round_mod = nil

	local function get_round()
		if round_mod then return round_mod end
		local ok, m = pcall(function()
			return require(rs:WaitForChild("Modules"):WaitForChild("CurrentRoundClient"))
		end)
		if ok and type(m) == "table" then round_mod = m end
		return round_mod
	end

	local function holds(container, name)
		return container ~= nil and container:FindFirstChild(name) ~= nil
	end

	local function lp_has_gun()
		return holds(lp.Character, "Gun") or holds(lp:FindFirstChildOfClass("Backpack"), "Gun")
	end

	local target_player = nil
	local target_char = nil
	local target_part = nil
	local target_hum = nil

	local function refresh_target()
		local found = nil
		local m = get_round()
		local data = m and m.PlayerData or nil
		if type(data) == "table" then
			local me = data[lp.Name]
			S.am_sheriff = (me ~= nil and (me.Role == "Sheriff" or me.Role == "Hero")) or lp_has_gun()
			for name, d in pairs(data) do
				if type(d) == "table" and d.Role == "Murderer" and not d.Dead then
					found = players:FindFirstChild(name)
					break
				end
			end
		else
			S.am_sheriff = lp_has_gun()
		end
		if not found then
			for _, plr in ipairs(players:GetPlayers()) do
				if plr ~= lp and holds(plr.Character, "Knife") then
					found = plr
					break
				end
			end
		end
		if found ~= target_player then
			target_player = found
			target_char = nil
			target_part = nil
			target_hum = nil
		end
		if not found then return end
		local char = found.Character
		if char ~= target_char then
			target_char = char
			target_part = nil
			target_hum = nil
		end
		if not char then return end
		if not target_part or not target_part.Parent then
			target_part = char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso")
		end
		if not target_hum or not target_hum.Parent then
			target_hum = char:FindFirstChildOfClass("Humanoid")
		end
	end

	local function target_alive()
		if not target_part or not target_part.Parent then return false end
		if not target_hum or not target_hum.Parent then return false end
		return target_hum.Health > 0
	end

	local ray_params = RaycastParams.new()
	ray_params.FilterType = Enum.RaycastFilterType.Exclude
	ray_params.IgnoreWater = false

	local ignore_base = {}
	local ignore_work = {}
	local ignore_time = 0

	local function refresh_ignore()
		local now = os.clock()
		if #ignore_base > 0 and now - ignore_time < 0.5 then return end
		ignore_time = now
		table.clear(ignore_base)
		local char = lp.Character
		if char then ignore_base[1] = char end
		local ok, tagged = pcall(function() return collection:GetTagged("WeaponPassthrough") end)
		if ok and type(tagged) == "table" then
			for k = 1, #tagged do
				ignore_base[#ignore_base + 1] = tagged[k]
			end
		end
	end

	local function trace(origin, direction)
		refresh_ignore()
		table.clear(ignore_work)
		for k = 1, #ignore_base do ignore_work[k] = ignore_base[k] end
		local result = nil
		for _ = 1, 6 do
			ray_params.FilterDescendantsInstances = ignore_work
			result = workspace:Raycast(origin, direction, ray_params)
			if not result then break end
			local inst = result.Instance
			if not inst then break end
			local ok, tr = pcall(function() return inst.Transparency end)
			if not ok or tr ~= 1 then break end
			ignore_work[#ignore_work + 1] = inst
		end
		return result
	end

	local function gun_attachment()
		local char = lp.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if not hrp then return nil, nil end
		return hrp:FindFirstChild("GunRaycastAttachment"), hrp
	end

	local function origin_cframe()
		local att, hrp = gun_attachment()
		if att then return att.WorldCFrame end
		if hrp then return hrp.CFrame end
		return nil
	end

	local function grav()
		local ok, g = pcall(function() return workspace.Gravity end)
		if ok and type(g) == "number" and g > 0 then return g end
		return 0
	end

	local P = {
		snap = 48,
		ring = 48,
		hit_r = 2.1,
		pad = 2.6,
		min_span = 5,
		max_span = 90,
		acc_t = 0.15,
		acc_max = 280,
		acc_min = 40,
		speed_floor = 26,
		speed_head = 1.3,
	}

	local snap_t = table.create(P.snap, 0)
	local snap_p = table.create(P.snap, Vector3.zero)
	local snap_n = 0
	local snap_i = 0

	local TR = {
		part = nil,
		pos = nil,
		time = 0,
		vel = Vector3.zero,
		gap = 0,
		ready = false,
		fresh = Vector3.zero,
		air = false,
		air_since = 0,
		jumping = false,
		jump_v = 0,
		fresh_ok = false,
		turn = 0,
		spoof = 0,
		clr = 0,
		air_edge = 0,
		jump_fresh = false,
	}

	local SK = {
		vt = table.create(P.ring, 0),
		dx = table.create(P.ring, 0),
		dz = table.create(P.ring, 0),
		vn = 0,
		vi = 0,
	}

	local EC = {
		ping = 0,
		rtt = 0,
		jitter = 0,
		seen = false,
		step = 0,
		step_seen = false,
	}

	local function step_push(dt)
		if dt <= 0 or dt > 0.5 then return end
		if EC.step_seen then
			EC.step = EC.step * 0.85 + dt * 0.15
		else
			EC.step = dt
			EC.step_seen = true
		end
	end

	local function sample_span()
		local span = math.max(EC.step, TR.gap)
		if span <= 0 then return 0 end
		return span
	end

	local HY = {
		pos = {},
		w = {},
		n = 0,
		weight = 0,
		primary = nil,
		stamp = 0,
		conf = 0,
	}

	local ground_params = RaycastParams.new()
	ground_params.FilterType = Enum.RaycastFilterType.Exclude
	ground_params.IgnoreWater = true

	local ground_filter = {}
	local axis_pool = {}

	local function ground_below(pos, reach)
		table.clear(ground_filter)
		local n = 0
		local char = target_char
		if char then
			n = n + 1
			ground_filter[n] = char
		end
		local mine = lp.Character
		if mine then
			n = n + 1
			ground_filter[n] = mine
		end
		ground_params.FilterDescendantsInstances = ground_filter
		local res = workspace:Raycast(pos, Vector3.new(0, -reach, 0), ground_params)
		if res then return res.Position.Y end
		return nil
	end

	local function snap_push(now, pos)
		snap_i = snap_i % P.snap + 1
		snap_t[snap_i] = now
		snap_p[snap_i] = pos
		if snap_n < P.snap then snap_n = snap_n + 1 end
	end

	local function snap_get(k)
		local idx = (snap_i - k - 1) % P.snap + 1
		return snap_t[idx], snap_p[idx]
	end

	local function fit_velocity()
		if snap_n < 3 then return nil end
		local newest = snap_get(0)
		local used = 0
		local sum_d = 0
		local win = sample_span() * 4
		for k = 0, snap_n - 1 do
			local t = snap_get(k)
			if newest - t > win then break end
			used = used + 1
			sum_d = sum_d + t - newest
		end
		if used < 3 then return nil end
		local mean_d = sum_d / used
		local num = Vector3.zero
		local den = 0
		for k = 0, used - 1 do
			local t, p = snap_get(k)
			local d = t - newest - mean_d
			num = num + p * d
			den = den + d * d
		end
		if den < 1e-8 then return nil end
		return num / den, -mean_d
	end

	local function recent_velocity()
		if snap_n < 2 then return nil end
		local newest, head = snap_get(0)
		local fallback, fallback_age = nil, nil
		local target_span = sample_span() * 2
		local max_span = target_span * 2
		for k = 1, snap_n - 1 do
			local t, p = snap_get(k)
			local dt = newest - t
			if dt > max_span then break end
			if dt > 0 then
				fallback = (head - p) / dt
				fallback_age = dt * 0.5
				if dt >= target_span then
					return fallback, fallback_age
				end
			end
		end
		return fallback, fallback_age
	end

	local KIN = {
		ok = false,
		ax = 0,
		az = 0,
		smax = 0,
	}

	local function kin_clear()
		KIN.ok = false
		KIN.ax = 0
		KIN.az = 0
		KIN.smax = 0
	end

	local function fit_kin()
		if snap_n < 5 then return nil end
		local t0 = snap_get(0)
		local win = math.max(sample_span() * 5, 0.12)
		local scale = win
		local n, s1, s2, s3, s4 = 0, 0, 0, 0, 0
		local bx0, bx1, bx2 = 0, 0, 0
		local bz0, bz1, bz2 = 0, 0, 0
		for k = 0, snap_n - 1 do
			local t, p = snap_get(k)
			local age = t0 - t
			if age > win then break end
			local u = -age / scale
			local u2 = u * u
			n = n + 1
			s1 = s1 + u
			s2 = s2 + u2
			s3 = s3 + u2 * u
			s4 = s4 + u2 * u2
			bx0 = bx0 + p.X
			bx1 = bx1 + p.X * u
			bx2 = bx2 + p.X * u2
			bz0 = bz0 + p.Z
			bz1 = bz1 + p.Z * u
			bz2 = bz2 + p.Z * u2
		end
		if n < 5 then return nil end
		local det = n * (s2 * s4 - s3 * s3)
			- s1 * (s1 * s4 - s3 * s2)
			+ s2 * (s1 * s3 - s2 * s2)
		if math.abs(det) < 1e-9 then return nil end
		local function solve(b0, b1, b2)
			local d1 = n * (b1 * s4 - s3 * b2)
				- b0 * (s1 * s4 - s3 * s2)
				+ s2 * (s1 * b2 - b1 * s2)
			local d2 = n * (s2 * b2 - b1 * s3)
				- s1 * (s1 * b2 - b1 * s2)
				+ b0 * (s1 * s3 - s2 * s2)
			return d1 / det, d2 / det
		end
		local cx1, cx2 = solve(bx0, bx1, bx2)
		local cz1, cz2 = solve(bz0, bz1, bz2)
		local vx, vz = cx1 / scale, cz1 / scale
		local ax, az = 2 * cx2 / (scale * scale), 2 * cz2 / (scale * scale)
		if vx ~= vx or vz ~= vz or ax ~= ax or az ~= az then return nil end
		return Vector3.new(vx, 0, vz), Vector3.new(ax, 0, az)
	end

	local function kin_update()
		local kv, ka = fit_kin()
		if not kv then
			KIN.ok = false
			KIN.ax = 0
			KIN.az = 0
			return nil
		end
		KIN.ok = true
		local sp = math.sqrt(kv.X * kv.X + kv.Z * kv.Z)
		if sp > KIN.smax then
			KIN.smax = sp
		else
			KIN.smax = KIN.smax * 0.985 + sp * 0.015
		end
		if ka and not TR.air then
			local am = math.sqrt(ka.X * ka.X + ka.Z * ka.Z)
			local ax, az = ka.X, ka.Z
			if am > P.acc_max and am > 0 then
				ax = ax * P.acc_max / am
				az = az * P.acc_max / am
			end
			KIN.ax = KIN.ax * 0.5 + ax * 0.5
			KIN.az = KIN.az * 0.5 + az * 0.5
		else
			KIN.ax = KIN.ax * 0.5
			KIN.az = KIN.az * 0.5
		end
		return kv
	end

	local function snap_vel(k)
		local t0, p0 = snap_get(k)
		local t1, p1 = snap_get(k + 1)
		local d = t0 - t1
		if d <= 0 then return nil end
		return (p0 - p1) / d, d
	end

	local function vert_accel()
		if snap_n < 3 then return nil end
		local v0, d0 = snap_vel(0)
		local v1, d1 = snap_vel(1)
		if not v0 or not v1 then return nil end
		local span = (d0 + d1) * 0.5
		if span <= 1e-4 then return nil end
		return (v0.Y - v1.Y) / span
	end

	local function air_vy()
		if snap_n < 2 then return nil end
		local edge = TR.air_edge
		if edge <= 0 then return nil end
		local g = grav()
		local newest, head = snap_get(0)
		local want = sample_span() * 2
		local best = nil
		for k = 1, snap_n - 1 do
			local t, p = snap_get(k)
			if t < edge then break end
			local dt = newest - t
			if dt > 1e-4 then
				best = (head.Y - p.Y) / dt - 0.5 * g * dt
				if dt >= want then break end
			end
		end
		return best
	end

	local function body_clearance()
		local part = target_part
		local hum = target_hum
		if not part or not hum then return 0 end
		local ok, value = pcall(function() return part.Size.Y * 0.5 + hum.HipHeight end)
		if ok and type(value) == "number" and value > 0 then return value end
		return 0
	end

	local GC = {
		base = 0,
		seen = false,
	}

	local JL = {
		v = 0,
		seen = false,
	}

	local function stand_clearance()
		if GC.seen then return GC.base end
		return body_clearance()
	end

	local function engine_vel(part)
		local ok, v = pcall(function() return part.AssemblyLinearVelocity end)
		if not ok or typeof(v) ~= "Vector3" then
			ok, v = pcall(function() return part.Velocity end)
		end
		if not ok or typeof(v) ~= "Vector3" then return nil end
		if v.Magnitude ~= v.Magnitude then return nil end
		return v
	end

	local function vel_trust(pv, ev)
		if not pv or not ev then return 0 end
		local ph = Vector3.new(pv.X, 0, pv.Z)
		local eh = Vector3.new(ev.X, 0, ev.Z)
		local pm, em = ph.Magnitude, eh.Magnitude
		if pm < 1 and em < 1 then return 1 end
		if pm < 1 or em < 1 then return 0 end
		local ratio = em / pm
		if ratio > 1.5 or ratio < 0.6 then return 0 end
		local align = ph.Unit:Dot(eh.Unit)
		if align < 0.7 then return 0 end
		local a = math.clamp((align - 0.7) / 0.25, 0, 1)
		local r = 1 - math.clamp(math.abs(ratio - 1) / 0.4, 0, 1)
		return a * r
	end

	local function phase_velocity(v, age, air)
		if not v then return nil end
		local y = 0
		if air then
			y = v.Y - grav() * math.clamp(age or 0, 0, sample_span() * 4)
		end
		return Vector3.new(v.X, y, v.Z)
	end

	local function merge_vel(fit, fit_age, fast, fast_age, engine, engine_age, air)
		local stable = phase_velocity(fit, fit_age, air)
		local instant = phase_velocity(fast, fast_age, air)
		local turn = 0
		if stable and instant then
			local sh = Vector3.new(stable.X, 0, stable.Z)
			local ih = Vector3.new(instant.X, 0, instant.Z)
			if sh.Magnitude > 1 and ih.Magnitude > 1 then
				turn = math.acos(math.clamp(sh.Unit:Dot(ih.Unit), -1, 1)) / math.pi
			end
		end
		local base = instant or stable
		if not base then return Vector3.zero, 0, nil, 0 end
		if stable and instant then
			local agility = math.clamp(turn * 2.2, 0, 1)
			base = stable:Lerp(instant, 0.4 + 0.6 * agility)
		end
		local trust = 0
		if engine then
			local live = phase_velocity(engine, engine_age, air)
			trust = vel_trust(base, live)
			if trust > 0 and air then
				base = Vector3.new(base.X, base.Y, base.Z):Lerp(Vector3.new(base.X, live.Y, base.Z), trust * 0.35)
			end
		end
		return base, turn, instant or stable, trust
	end

	local function vel_push(now, hx, hz)
		SK.vi = SK.vi % P.ring + 1
		SK.vt[SK.vi] = now
		SK.dx[SK.vi] = hx
		SK.dz[SK.vi] = hz
		if SK.vn < P.ring then SK.vn = SK.vn + 1 end
	end

	local function track_clear()
		TR.part = nil
		TR.pos = nil
		TR.vel = Vector3.zero
		TR.gap = 0
		TR.ready = false
		TR.fresh = Vector3.zero
		TR.air = false
		TR.jumping = false
		TR.jump_v = 0
		TR.fresh_ok = false
		TR.turn = 0
		TR.spoof = 0
		TR.clr = 0
		TR.air_edge = 0
		TR.jump_fresh = false
		GC.base = 0
		GC.seen = false
		JL.v = 0
		JL.seen = false
		snap_n, snap_i = 0, 0
		SK.vn, SK.vi = 0, 0
		kin_clear()
	end

	local function track_seed(part, pos, now)
		TR.part = part
		TR.pos = pos
		TR.time = now
		TR.vel = Vector3.zero
		TR.fresh = Vector3.zero
		TR.fresh_ok = false
		TR.turn = 0
		TR.jump_v = 0
		TR.gap = 0
		TR.ready = false
		TR.spoof = 0
		TR.air_edge = 0
		TR.jump_fresh = false
		GC.base = 0
		GC.seen = false
		snap_n, snap_i = 0, 0
		kin_clear()
		snap_push(now, pos)
	end

	local function track_fresh(now)
		local part = target_part
		if not part or not part.Parent then
			TR.fresh_ok = false
			return
		end
		local pos = part.Position
		local g = grav()
		local sv = snap_vel(0)
		local vy = sv and sv.Y or 0
		local accel = vert_accel()
		local falling = accel ~= nil and accel < -g * 0.5
		local guess = stand_clearance()
		local reach = guess + 6 + math.abs(vy) * sample_span() * 4
		local air
		local gy = ground_below(pos, reach)
		if gy then
			local clr = pos.Y - gy
			TR.clr = clr
			if math.abs(vy) < 1 and not falling then
				if GC.seen then
					if clr < GC.base then
						GC.base = GC.base * 0.7 + clr * 0.3
					else
						GC.base = GC.base * 0.98 + clr * 0.02
					end
				else
					GC.base = clr
					GC.seen = true
				end
			end
			local floor = GC.seen and GC.base or guess
			local tol = math.max(floor * 0.35, 1)
			air = clr > floor + tol
			if not air and falling and math.abs(vy) > 4 and clr > floor + 0.35 then
				air = true
			end
		else
			air = true
		end
		if air ~= TR.air then
			TR.air_edge = now
			if air then
				TR.air_since = now
				TR.jump_fresh = true
				TR.jump_v = JL.seen and JL.v or math.max(vy, 0)
			else
				TR.jump_fresh = false
				TR.jump_v = 0
			end
		end
		local model_vy = TR.jump_v - g * math.max(0, now - TR.air_since)
		TR.air = air
		TR.jumping = air and (vy > 1 or model_vy > 1)
	end

	local function track(now)
		local part = target_part
		if not part or not part.Parent then
			if TR.part then track_clear() end
			return
		end
		track_fresh(now)
		local pos = part.Position
		if part ~= TR.part or not TR.pos then
			track_seed(part, pos, now)
			return
		end
		local dt = now - TR.time
		if dt > 0.75 or (pos - TR.pos).Magnitude > 140 then
			track_seed(part, pos, now)
			return
		end
		if dt <= 0 then return end
		if (pos - TR.pos).Magnitude == 0 then
			if TR.gap > 0 and dt >= TR.gap then
				TR.vel = Vector3.zero
				TR.fresh = Vector3.zero
			end
			return
		end
		step_push(dt)
		TR.gap = dt
		snap_push(now, pos)
		TR.pos = pos
		TR.time = now
		local fit, fit_age = fit_velocity()
		local fast, fast_age = recent_velocity()
		local engine = engine_vel(part)
		local fresh, turn, instant, trust = merge_vel(fit, fit_age, fast, fast_age, engine, sample_span() * 0.5, TR.air)
		local kv = kin_update()
		if kv then
			fresh = Vector3.new(kv.X, fresh.Y, kv.Z)
		end
		if engine and trust <= 0 then
			if TR.spoof < 20 then TR.spoof = TR.spoof + 1 end
		elseif TR.spoof > 0 then
			TR.spoof = TR.spoof - 1
		end
		if TR.air then
			local vy = air_vy()
			if vy then
				fresh = Vector3.new(fresh.X, vy, fresh.Z)
				local since = math.max(0, now - TR.air_edge)
				if TR.jump_fresh and since <= 0.2 then
					local impulse = vy + grav() * since
					if impulse > 1 then
						if JL.seen then
							JL.v = JL.v * 0.7 + impulse * 0.3
						else
							JL.v = impulse
							JL.seen = true
						end
						if impulse > TR.jump_v then TR.jump_v = impulse end
					end
				else
					TR.jump_fresh = false
				end
			end
		end
		TR.vel = fresh
		TR.ready = fit ~= nil or fast ~= nil
		TR.fresh = TR.vel
		TR.fresh_ok = TR.ready
		TR.turn = turn
		local raw = instant or fresh
		vel_push(now, raw.X, raw.Z)
	end

	local function raw_rtt()
		local a, b
		local ok, ms = pcall(function()
			return stats.Network.ServerStatsItem["Data Ping"]:GetValue()
		end)
		if ok and type(ms) == "number" and ms == ms and ms > 4 and ms < 800 then
			a = ms / 1000
		end
		local fine, value = pcall(function() return lp:GetNetworkPing() end)
		if fine and type(value) == "number" and value == value and value > 0 then
			local rtt = value * 2
			if rtt > 0.004 and rtt < 0.8 then b = rtt end
		end
		if a and b then return (a + b) * 0.5 end
		return a or b
	end

	local function sample_ping()
		local rtt = raw_rtt()
		if not rtt or rtt ~= rtt then return end
		rtt = math.clamp(rtt, 0, 1)
		if EC.seen then
			EC.jitter = EC.jitter * 0.9 + math.abs(rtt - EC.rtt) * 0.1
			EC.rtt = EC.rtt * 0.82 + rtt * 0.18
		else
			EC.rtt = rtt
			EC.jitter = 0
			EC.seen = true
		end
		EC.ping = EC.rtt
	end

	local function lead_time()
		if not EC.seen then return 0 end
		local stale = 0
		if TR.time > 0 and EC.step_seen then
			stale = math.clamp(os.clock() - TR.time, 0, EC.step)
		end
		return math.clamp(EC.rtt + EC.jitter * 0.5 + stale, 0, 1)
	end

	local function rotate_y(v, ang)
		local c, s = math.cos(ang), math.sin(ang)
		return Vector3.new(v.X * c - v.Z * s, v.Y, v.X * s + v.Z * c)
	end

	local function dir_stats(win)
		if SK.vn < 4 then return 1, 0 end
		win = math.max(win, sample_span() * 3)
		local newest = SK.vt[SK.vi]
		local sx, sz, n = 0, 0, 0
		local prev = nil
		local turn, turn_n = 0, 0
		local oldest = newest
		for k = 0, SK.vn - 1 do
			local idx = (SK.vi - k - 1) % P.ring + 1
			local t = SK.vt[idx]
			if newest - t > win then break end
			local hx, hz = SK.dx[idx], SK.dz[idx]
			local m = math.sqrt(hx * hx + hz * hz)
			if m > 0 then
				sx = sx + hx / m
				sz = sz + hz / m
				n = n + 1
				local ang = math.atan2(hz, hx)
				if prev then
					local d = ang - prev
					while d > math.pi do d = d - 6.2831853 end
					while d < -math.pi do d = d + 6.2831853 end
					turn = turn + d
					turn_n = turn_n + 1
				end
				prev = ang
				oldest = t
			end
		end
		if n < 2 then return 1, 0 end
		local coh = math.clamp(math.sqrt(sx * sx + sz * sz) / n, 0, 1)
		local omega = 0
		local elapsed = newest - oldest
		if turn_n >= 1 and elapsed > 1e-3 then
			omega = -turn / elapsed
		end
		return coh, omega
	end

	local function predict_from(base, sa, sb, fh, now)
		local span = math.max(0, sa + sb)
		local g = grav()
		local dir = fh
		if dir.Magnitude == 0 then
			dir = Vector3.new(TR.vel.X, 0, TR.vel.Z)
		end
		local x, z
		if span > 0 and KIN.ok then
			local age = math.clamp(now - TR.time, 0, sample_span() * 2)
			local ax, az = KIN.ax, KIN.az
			if TR.air or math.sqrt(ax * ax + az * az) < P.acc_min then ax, az = 0, 0 end
			local vx = dir.X + ax * age
			local vz = dir.Z + az * age
			local ta = math.min(span, P.acc_t)
			local dx = vx * span + 0.5 * ax * ta * ta
			local dz = vz * span + 0.5 * az * ta * ta
			local reach = math.sqrt(dx * dx + dz * dz)
			local cap = math.max(KIN.smax * P.speed_head, P.speed_floor) * span
			if reach > cap and reach > 1e-6 then
				dx = dx * cap / reach
				dz = dz * cap / reach
			end
			x = base.X + dx
			z = base.Z + dz
		else
			local hspan = span
			if span > 0 and dir.Magnitude > 0 and not TR.air then
				local coh, omega = dir_stats(span)
				local conf = math.clamp(coh, 0, 1) * (1 - math.clamp(TR.turn, 0, 1) * 0.5)
				if omega ~= 0 then
					dir = rotate_y(dir, math.clamp(omega * span * 0.5 * conf, -0.6, 0.6))
				end
				hspan = span * (0.85 + 0.15 * conf)
			end
			x = base.X + dir.X * hspan
			z = base.Z + dir.Z * hspan
		end
		local y = base.Y
		if TR.air and span > 0 then
			local vy = TR.vel.Y
			local phase = math.max(0, now - TR.air_since)
			local modeled = TR.jump_v - g * phase
			if TR.jumping and TR.jump_v > 0 and g > 0 and phase <= TR.jump_v / g and modeled > vy then
				vy = modeled
			end
			y = base.Y + vy * span - 0.5 * g * span * span
			if y < base.Y then
				local clearance = stand_clearance()
				local reach = base.Y - y + clearance
				local gy = ground_below(Vector3.new(x, base.Y, z), reach)
				if gy then
					local floor = gy + clearance
					if y < floor then y = floor end
				end
			end
		end
		return Vector3.new(x, y, z)
	end

	local function build_hyps(base, now)
		table.clear(HY.pos)
		table.clear(HY.w)
		local horizon = S.predict and TR.ready and lead_time() or 0
		local fh = Vector3.new(TR.fresh.X, 0, TR.fresh.Z)
		HY.primary = predict_from(base, 0, horizon, fh, now)
		HY.n = 1
		HY.pos[1] = HY.primary
		HY.w[1] = 1
		HY.weight = 1
		HY.stamp = now
	end

	local function score_axis(anchor, axis)
		local covered = 0
		local lo, hi = 0, 0
		for k = 1, HY.n do
			local d = HY.pos[k] - anchor
			local a = d:Dot(axis)
			local perp = (d - axis * a).Magnitude
			if perp <= P.hit_r then
				covered = covered + HY.w[k]
				if a < lo then lo = a end
				if a > hi then hi = a end
			end
		end
		return covered, lo, hi
	end

	local function corridor_axes(anchor)
		table.clear(axis_pool)
		local n = 0
		local function add(v)
			if typeof(v) ~= "Vector3" or v.Magnitude < 1e-4 then return end
			local u = v.Unit
			for k = 1, n do
				if axis_pool[k]:Dot(u) > 0.985 then return end
			end
			n = n + 1
			axis_pool[n] = u
		end
		local fh = Vector3.new(TR.fresh.X, 0, TR.fresh.Z)
		if TR.air then add(TR.fresh) end
		add(fh)
		for k = 1, HY.n do
			add(HY.pos[k] - anchor)
		end
		add(TR.fresh)
		add(Vector3.new(0, 1, 0))
		return n
	end

	local function build_corridor(now)
		local part = target_part
		if not part or not part.Parent then return nil end
		local base = part.Position
		build_hyps(base, now)
		local anchor = HY.primary or base
		local count = corridor_axes(anchor)
		local best_axis, best_cov, best_lo, best_hi = nil, -1, 0, 0
		for k = 1, count do
			local axis = axis_pool[k]
			local cov, lo, hi = score_axis(anchor, axis)
			if cov > best_cov then
				best_axis, best_cov, best_lo, best_hi = axis, cov, lo, hi
			end
		end
		if not best_axis then return nil end
		HY.conf = HY.weight > 0 and best_cov / HY.weight or 0

		local pad = P.pad
		local origin = anchor + best_axis * (best_lo - pad)
		local aim = anchor + best_axis * (best_hi + pad)
		if (aim - origin).Magnitude < 4 then
			origin = anchor - best_axis * 4
			aim = anchor + best_axis * 4
		end
		return origin, aim, HY.conf, anchor
	end

	local pred_off = Vector3.zero
	local pred_stamp = 0

	local function lead_offset()
		local part = target_part
		if not part or not part.Parent then return Vector3.zero end
		if not S.predict or not TR.ready then return Vector3.zero end
		local base = part.Position
		local now = os.clock()
		local fh = Vector3.new(TR.fresh.X, 0, TR.fresh.Z)
		local point = predict_from(base, 0, lead_time(), fh, now)
		local off = point - base
		pred_stamp = now
		pred_off = off
		return pred_off
	end

	local function cloud_confidence()
		local anchor = HY.primary
		if not anchor or HY.n == 0 or HY.weight <= 0 then return 0 end
		local covered = 0
		for k = 1, HY.n do
			if (HY.pos[k] - anchor).Magnitude <= P.hit_r then
				covered = covered + HY.w[k]
			end
		end
		return covered / HY.weight
	end
	local hit_names = {
		"HumanoidRootPart", "UpperTorso", "Torso", "LowerTorso", "Head",
		"RightUpperArm", "LeftUpperArm", "Right Arm", "Left Arm",
		"RightUpperLeg", "LeftUpperLeg", "Right Leg", "Left Leg",
		"RightLowerLeg", "LeftLowerLeg",
	}

	local hit_parts = {}
	local hit_count = 0
	local hit_char = nil

	local function refresh_parts()
		local char = target_char
		if char == hit_char then return end
		table.clear(hit_parts)
		hit_count = 0
		hit_char = char
		if not char then return end
		for k = 1, #hit_names do
			local part = char:FindFirstChild(hit_names[k])
			if part and part:IsA("BasePart") then
				hit_count = hit_count + 1
				hit_parts[hit_count] = part
			end
		end
	end

	local function los_clear(origin, point)
		if not origin or not point then return false end
		local delta = point - origin
		local dist = delta.Magnitude
		if dist < 0.5 then return true end
		if dist > MAX_RANGE then return false end
		local hit = trace(origin, delta)
		if not hit then return true end
		local inst = hit.Instance
		local char = target_char
		if inst and char and (inst == char or inst:IsDescendantOf(char)) then return true end
		return (hit.Position - origin).Magnitude >= dist - 0.75
	end

	local function pick_point(origin, strict)
		refresh_parts()
		if hit_count == 0 then return nil end
		local off = lead_offset()
		local first = nil
		for k = 1, hit_count do
			local part = hit_parts[k]
			if not part.Parent then
				hit_char = nil
			else
				local point = part.Position + off
				if not origin then return point end
				if not first then first = point end
				if los_clear(origin, point) then return point end
			end
		end
		if strict then return nil end
		return first
	end

	local force_att = nil
	local force_saved = nil
	local force_stamp = 0

	local function restore_origin()
		local att = force_att
		if not att then return end
		local saved = force_saved
		force_att = nil
		force_saved = nil
		if saved then
			pcall(function()
				if att.Parent then att.CFrame = saved end
			end)
		end
	end

	local function push_origin(cf)
		local att = gun_attachment()
		if not att then return false end
		if force_att and force_att ~= att then restore_origin() end
		if not force_att then
			local ok, saved = pcall(function() return att.CFrame end)
			if not ok or typeof(saved) ~= "CFrame" then return false end
			force_att = att
			force_saved = saved
		end
		force_stamp = os.clock()
		local ok = pcall(function() att.WorldCFrame = cf end)
		if not ok then
			restore_origin()
			return false
		end
		task.defer(restore_origin)
		return true
	end

	local function is_target_hit(inst)
		local char = target_char
		if not inst or not char then return false end
		return inst == char or inst:IsDescendantOf(char)
	end

	local function force_clear(origin, aim)
		local hit = trace(origin, aim - origin)
		if not hit then return false end
		return is_target_hit(hit.Instance)
	end

	local function force_velocity()
		if TR.fresh_ok and TR.fresh.Magnitude > 0.5 then return TR.fresh end
		if TR.ready and TR.vel.Magnitude > 0.5 then return TR.vel end
		return Vector3.zero
	end

	local function resolve_force()
		local part = target_part
		if not part or not part.Parent then return nil end
		local live = part.Position
		local now = os.clock()

		local origin, aim, conf, anchor = build_corridor(now)
		if origin and aim then
			local axis = aim - origin
			local span = axis.Magnitude
			if span > 1e-3 then
				local u = axis / span
				local mark = anchor or live
				local behind = (mark - origin):Dot(u)
				if behind < P.pad then
					origin = origin - u * (P.pad - behind)
				end
				local ahead = (aim - mark):Dot(u)
				if ahead < P.min_span then
					aim = mark + u * P.min_span
				end
				local want = S.stand_off
				while want > 0 do
					local probe = origin - u * want
					if (aim - probe).Magnitude <= P.max_span
						and los_clear(probe, mark)
						and los_clear(probe, live) then
						origin = probe
						break
					end
					want = want - 3
				end
				if (aim - origin).Magnitude > P.max_span then
					origin = aim - u * P.max_span
				end
				return CFrame.new(origin, aim), CFrame.new(aim), conf or 0, mark
			end
		end

		local vel = force_velocity()
		local dir = Vector3.new(0, -1, 0)
		if vel.Magnitude > 3 then
			dir = vel.Unit
		else
			local mine = origin_cframe()
			if mine then
				local delta = live - mine.Position
				if delta.Magnitude > 2 then dir = delta.Unit end
			end
		end
		local back = live - dir * 6
		local front = live + dir * math.max(P.min_span, vel.Magnitude * lead_time() + 8)
		if not force_clear(back, front) then
			back = live - dir * 2.5
		end
		return CFrame.new(back, front), CFrame.new(front), 0, live
	end

	local function shot_shift(dt)
		if not S.predict or not TR.ready or dt <= 0 then return Vector3.zero end
		local shift = Vector3.new(TR.vel.X * dt, 0, TR.vel.Z * dt)
		if TR.air then
			local g = grav()
			local horizon = lead_time()
			local vy = TR.vel.Y
			local phase = math.max(0, os.clock() - TR.air_since)
			local modeled = TR.jump_v - g * phase
			if TR.jumping and TR.jump_v > 0 and g > 0 and phase <= TR.jump_v / g and modeled > vy then vy = modeled end
			shift = Vector3.new(shift.X, vy * dt - g * horizon * dt - 0.5 * g * dt * dt, shift.Z)
		end
		return shift
	end

	local function compensate_force(origin_cf, aim_cf, started)
		local shift = shot_shift(math.max(0, os.clock() - started))
		if shift == Vector3.zero then return origin_cf, aim_cf end
		local origin = origin_cf.Position + shift
		local aim = aim_cf.Position + shift
		return CFrame.new(origin, aim), CFrame.new(aim)
	end

	local function resolve_shot()
		if not S.enabled or not S.am_sheriff or not target_alive() then return nil end
		if S.force then
			local started = os.clock()
			local origin_cf, aim_cf = resolve_force()
			if origin_cf and aim_cf then
				origin_cf, aim_cf = compensate_force(origin_cf, aim_cf, started)
				if push_origin(origin_cf) then return aim_cf end
			end
		end
		local cf = origin_cframe()
		local aim = pick_point(cf and cf.Position or nil, false)
		if not aim then return nil end
		return CFrame.new(aim)
	end

	local function compensate_resolve(cf)
		if S.force or typeof(cf) ~= "CFrame" then return cf end
		return CFrame.new(cf.Position + shot_shift(math.max(0, os.clock() - pred_stamp)))
	end

	local weapon_service = nil
	local orig_mouse = nil
	local orig_screen = nil
	local hook_mouse = nil
	local hook_screen = nil

	local function get_weapon_service()
		if weapon_service then return weapon_service end
		local ok, m = pcall(function()
			return require(rs:WaitForChild("ClientServices"):WaitForChild("WeaponService"))
		end)
		if ok and type(m) == "table" then weapon_service = m end
		return weapon_service
	end

	local function install_hooks()
		local m = get_weapon_service()
		if not m then return end
		if not hook_mouse then
			local function knife_aim()
				local fn = getgenv().KNIFE_AIM_RESOLVE
				if type(fn) ~= "function" then return nil end
				local ok, cf = pcall(fn)
				if ok and typeof(cf) == "CFrame" then return cf end
				return nil
			end
			hook_mouse = function(self, ...)
				sample_ping()
				local ok, cf = pcall(resolve_shot)
				if ok and cf then return compensate_resolve(cf) end
				local kcf = knife_aim()
				if kcf then return kcf end
				return orig_mouse(self, ...)
			end
			hook_screen = function(self, x, y, ...)
				sample_ping()
				local ok, cf = pcall(resolve_shot)
				if ok and cf then return compensate_resolve(cf) end
				local kcf = knife_aim()
				if kcf then return kcf end
				return orig_screen(self, x, y, ...)
			end
		end
		pcall(function() setreadonly(m, false) end)
		if type(m.GetMouseTargetCFrame) == "function" and m.GetMouseTargetCFrame ~= hook_mouse then
			orig_mouse = m.GetMouseTargetCFrame
			pcall(function() m.GetMouseTargetCFrame = hook_mouse end)
		end
		if type(m.GetTargetPosition) == "function" and m.GetTargetPosition ~= hook_screen then
			orig_screen = m.GetTargetPosition
			pcall(function() m.GetTargetPosition = hook_screen end)
		end
	end

	local gun_fired_conn = nil
	local last_fire_stamp = 0

	local function on_gun_fired(tool)
		if typeof(tool) ~= "Instance" then return end
		local char = lp.Character
		if not char then return end
		local ok, mine = pcall(function() return tool:IsDescendantOf(char) end)
		if not ok or not mine then return end
		local now = os.clock()
		if last_fire_stamp > 0 and want_since > 0 and want_since <= last_fire_stamp then
			gap_push(now - last_fire_stamp)
		end
		last_fire_stamp = now
	end

	local function connect_gun_fired()
		if gun_fired_conn then return end
		local m = get_weapon_service()
		if not m then return end
		local ev = m.GunFired
		if typeof(ev) ~= "Instance" then return end
		gun_fired_conn = ev.OnClientEvent:Connect(function(tool)
			pcall(on_gun_fired, tool)
		end)
	end

	local function get_gun()
		local char = lp.Character
		if char then
			local g = char:FindFirstChild("Gun")
			if g then return g, true end
		end
		local bp = lp:FindFirstChildOfClass("Backpack")
		if bp then
			local g = bp:FindFirstChild("Gun")
			if g then return g, false end
		end
		return nil, false
	end

	local function fire_gun(gun, start_cf, aim_cf)
		if not gun or not start_cf or not aim_cf then return false end
		local remote = gun:FindFirstChild("Shoot")
		if not remote or not remote:IsA("RemoteEvent") then return false end
		return (pcall(function() remote:FireServer(start_cf, aim_cf) end))
	end

	local function auto_step(now)
		if not S.auto_on or not S.enabled or not S.am_sheriff or getgenv().AUTOFARM_HOLD or not target_alive() then
			want_since = 0
			return
		end
		local gun, equipped = get_gun()
		if not gun then
			want_since = 0
			return
		end
		if gun ~= gap_gun then
			gap_gun = gun
			gap_reset()
		end
		if not equipped then
			want_since = 0
			local hum = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
			if hum then pcall(function() hum:EquipTool(gun) end) end
			return
		end
		if want_since == 0 then want_since = now end
		local hold = S.auto_delay
		if hold < S.fire_gap then hold = S.fire_gap end
		local since = last_fire_stamp > 0 and last_fire_stamp or S.last_shot
		if now - since < hold then return end
		if S.force then
			local started = os.clock()
			local origin_cf, aim_cf = resolve_force()
			if not origin_cf or not aim_cf then return end
			origin_cf, aim_cf = compensate_force(origin_cf, aim_cf, started)
			if fire_gun(gun, origin_cf, aim_cf) then
				S.last_shot = now
			end
			return
		end
		local cf = origin_cframe()
		if not cf then return end
		local aim = pick_point(cf.Position, true)
		if not aim then return end
		local aim_cf = compensate_resolve(CFrame.new(aim))
		if fire_gun(gun, cf, aim_cf) then
			S.last_shot = now
		end
	end

	local watch_conns = {}

	local function clear_watch()
		for k = 1, #watch_conns do
			local conn = watch_conns[k]
			pcall(function() conn:Disconnect() end)
		end
		table.clear(watch_conns)
	end

	local function setup_watch()
		clear_watch()
		local m = get_round()
		if m and m.PlayerDataChanged then
			watch_conns[#watch_conns + 1] = m.PlayerDataChanged.Event:Connect(function()
				pcall(refresh_target)
			end)
		end
		watch_conns[#watch_conns + 1] = lp.CharacterAdded:Connect(function()
			task.wait(0.3)
			pcall(refresh_target)
		end)
	end

	local next_role = 0
	local next_hook = 0

	local function tick()
		if force_att and os.clock() - force_stamp > 0.05 then restore_origin() end
		if not S.enabled then return end
		local now = os.clock()
		if now >= next_role then
			next_role = now + 0.2
			refresh_target()
		end
		sample_ping()
		track(now)
		if now >= next_hook then
			next_hook = now + 1
			install_hooks()
			connect_gun_fired()
		end
		auto_step(now)
	end

	local main_conn = run.Heartbeat:Connect(function()
		pcall(tick)
	end)

	getgenv().SILENT_INSTALL_HOOKS = function()
		pcall(install_hooks)
	end

	getgenv().SILENT_DBG = function()
		local coh, omega = dir_stats(lead_time())
		return {
			target = target_player and target_player.Name or "none",
			ping = EC.ping,
			rtt = EC.rtt,
			jitter = EC.jitter,
			step = EC.step,
			lead = lead_time(),
			coherence = coh,
			omega = omega,
			turn = TR.turn,
			spoof = TR.spoof,
			clearance = TR.clr,
			ground = GC.seen and GC.base or 0,
			jump_learned = JL.seen and JL.v or 0,
			jump_v = TR.jump_v,
			fire_gap = S.fire_gap,
			want_since = want_since,
			conf_point = cloud_confidence(),
			conf_ray = HY.conf,
			gap = TR.gap,
			airborne = TR.air,
			vel_fresh = TR.fresh,
			vel_pos = TR.vel,
		}
	end

	task.spawn(function()
		pcall(install_hooks)
		pcall(connect_gun_fired)
	end)

	getgenv().SILENT_UNLOAD = function()
		S.enabled = false
		S.predict = false
		S.force = false
		S.auto_on = false
		getgenv().SILENT_AIM_ACTIVE = false
		restore_origin()
		clear_watch()
		track_clear()
		if gun_fired_conn then
			pcall(function() gun_fired_conn:Disconnect() end)
			gun_fired_conn = nil
		end
		if main_conn then
			pcall(function() main_conn:Disconnect() end)
			main_conn = nil
		end
		local m = weapon_service
		if m then
			pcall(function() setreadonly(m, false) end)
			if orig_mouse then
				pcall(function() m.GetMouseTargetCFrame = orig_mouse end)
			end
			if orig_screen then
				pcall(function() m.GetTargetPosition = orig_screen end)
			end
		end
	end
end

local LOGO_URL = "https://raw.githubusercontent.com/DuntSunrise/DuntLibrary/refs/heads/main/1791368728932.jpg"
local TG_LINK = "t.me/PressureBypass"

local RawWindow = DuntUI.new({
    Title = "KvantScript",
    Subtitle = TG_LINK,
    Icon = LOGO_URL,
    Rank = "DelvaseBypass",
    ScriptName = "KvantScript",
    Animation = "Pixels",
    Screen = true,
    Theme = "Dark",
    Columns = 2,
    Lock = true,
    ToggleKey = Enum.KeyCode.RightShift,
})

local function adaptSection(section)
    local api = {}
    function api:Toggle(o)
        o = o or {}
        local ok, res = pcall(function()
            return section:Toggle({
                Name = o.Title or o.Name or "Toggle",
                Default = o.Value == true or o.Default == true,
                Flag = o.Flag,
                Callback = o.Callback,
            })
        end)
        return ok and res or nil
    end
    function api:Slider(o)
        o = o or {}
        local v = o.Value
        local min, max, def = 0, 100, 0
        if type(v) == "table" then
            min = v.Min or 0
            max = v.Max or 100
            def = v.Default or min
        else
            min = o.Min or 0
            max = o.Max or 100
            def = o.Default or min
        end
        local ok, res = pcall(function()
            return section:Slider({
                Name = o.Title or o.Name or "Slider",
                Min = min,
                Max = max,
                Default = def,
                Increment = o.Step or o.Increment or 1,
                Flag = o.Flag,
                Callback = o.Callback,
            })
        end)
        return ok and res or nil
    end
    function api:Dropdown(o)
        o = o or {}
        local opts = o.Values or o.Options or o.Items or {}
        local def = o.Value or o.Default or opts[1]
        local ok, res = pcall(function()
            return section:Dropdown({
                Name = o.Title or o.Name or "Dropdown",
                Options = opts,
                Default = def,
                Flag = o.Flag,
                Callback = function(val)
                    if not o.Callback then return end
                    if type(val) == "table" then
                        o.Callback(val[1] or val)
                    else
                        o.Callback(val)
                    end
                end,
            })
        end)
        return ok and res or nil
    end
    function api:Colorpicker(o)
        o = o or {}
        local ok, res = pcall(function()
            return section:ColorPicker({
                Name = o.Title or o.Name or "Color",
                Default = o.Default or Color3.fromRGB(255, 255, 255),
                Flag = o.Flag,
                Callback = o.Callback,
            })
        end)
        return ok and res or nil
    end
    function api:Button(o)
        o = o or {}
        local ok, res = pcall(function()
            return section:Button({
                Name = o.Title or o.Name or "Button",
                Callback = o.Callback or function() end,
            })
        end)
        return ok and res or nil
    end
    function api:Textbox(o)
        o = o or {}
        local ok, res = pcall(function()
            if section.Textbox then
                return section:Textbox({
                    Name = o.Title or o.Name or "Input",
                    Default = o.Default or o.Value or "",
                    Placeholder = o.Placeholder or "",
                    Flag = o.Flag,
                    Callback = o.Callback,
                })
            end
            return nil
        end)
        return ok and res or nil
    end
    function api:Paragraph(o)
        o = o or {}
        local title = tostring(o.Title or "")
        local desc = tostring(o.Desc or "")
        local text = title
        if desc ~= "" then
            text = title .. " | " .. desc
        end
        local label
        pcall(function()
            label = section:Label(text)
        end)
        return {
            SetDesc = function(_, d)
                pcall(function()
                    if label and label.Set then
                        label:Set(title .. " | " .. tostring(d))
                    end
                end)
            end,
            Set = function(_, d)
                pcall(function()
                    if label and label.Set then
                        label:Set(tostring(d))
                    end
                end)
            end,
        }
    end
    return api
end

local Window = {}
local _tabMap = {}
function Window:Tab(opts)
    opts = opts or {}
    local name = opts.Title or opts.Name or "Tab"
    local rawTab
    local ok, res = pcall(function()
        return RawWindow:Tab(name)
    end)
    if ok then rawTab = res end
    local dummy = adaptSection({
        Toggle = function() end,
        Slider = function() end,
        Dropdown = function() end,
        ColorPicker = function() end,
        Button = function() end,
        Label = function() return { Set = function() end } end,
        Textbox = function() end,
    })
    if not rawTab then
        return dummy
    end
    local secCache = {}
    local function makeSec(secName, side)
        local key = tostring(secName or "Main") .. "|" .. tostring(side or "")
        if secCache[key] then
            return secCache[key]
        end
        local sec
        local ok2, res2 = pcall(function()
            if side then
                return rawTab:Section(secName, side)
            end
            return rawTab:Section(secName)
        end)
        if ok2 then
            sec = res2
        end
        if not sec then
            return dummy
        end
        local adapted = adaptSection(sec)
        secCache[key] = adapted
        return adapted
    end
    local api = {}
    function api:Section(secName, side)
        return makeSec(secName, side)
    end

    local fallback = dummy
    setmetatable(api, { __index = fallback })
    _tabMap[api] = rawTab
    return api
end
function Window:SelectTab(tab)
    pcall(function()
        local raw = _tabMap[tab]
        if raw and RawWindow.Select then
            RawWindow:Select(raw)
        end
    end)
end

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer

if type(table.clear) ~= "function" then
    function table.clear(t)
        for k in pairs(t) do t[k] = nil end
    end
end
if type(table.create) ~= "function" then
    function table.create(n, val)
        local t = {}
        for i = 1, n do t[i] = val end
        return t
    end
end

local Camera = Workspace.CurrentCamera

local function table_clear(t)
    if type(t) ~= "table" then return end
    local native = rawget(table, "clear")
    if native then
        native(t)
        return
    end
    for k in pairs(t) do
        t[k] = nil
    end
end

local WalkSpeedValue = 16
local JumpPowerValue = 50
local InfJump = false
local SpeedGlitch = false
local SpeedGlitchValue = 50

local AutoGrab = false
local GunNotify = false
local SuccessNotify = false
local isGrabbing = false
local PlayerStatus = "Spectate"
local statusLabelRef = nil

local root, humanoid

local function notify(title, content)
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = tostring(title or "KvantScript"),
            Text = tostring(content or ""),
            Duration = 3,
        })
    end)
end

local noclip_on = false
local noclip_cache = {}

local function noclip_restore()
    for p, v in pairs(noclip_cache) do
        if p and p.Parent then
            pcall(function()
                p.CanCollide = v
            end)
        end
    end
    noclip_cache = {}
end

local function setNoclip(on)
    noclip_on = on
    if not on then
        noclip_restore()
    end
end

RunService.Stepped:Connect(function()
    if not noclip_on then
        return
    end
    if (getgenv().FLING_ACTIVE or 0) ~= 0 then
        if next(noclip_cache) ~= nil then
            noclip_restore()
        end
        return
    end
    local c = LocalPlayer.Character
    if not c then
        return
    end
    for _, p in ipairs(c:GetDescendants()) do
        if p:IsA("BasePart") and p.CanCollide then
            if noclip_cache[p] == nil then
                noclip_cache[p] = true
            end
            p.CanCollide = false
        end
    end
end)

local boost_on = false
local boost_value = 40
local boost_strafe_on = false
local boost_auto_strafe_on = false
local was_jumping = false
local is_boosting = false
local bhop_speed = 0
local jump_held_at = 0
local last_cam_yaw = nil

UserInputService.JumpRequest:Connect(function()
    jump_held_at = os.clock()
end)

local function jump_is_held()
    if os.clock() - jump_held_at < 0.5 then
        return true
    end
    local ok, down = pcall(function()
        return UserInputService:IsKeyDown(Enum.KeyCode.Space)
    end)
    if ok and down then
        return true
    end
    return false
end

local function cam_yaw()
    local cam = Workspace.CurrentCamera
    if not cam then
        return nil
    end
    local look = cam.CFrame.LookVector
    return math.atan2(-look.X, -look.Z)
end

RunService.Heartbeat:Connect(function()
    if not boost_on then
        was_jumping = false
        is_boosting = false
        bhop_speed = 0
        last_cam_yaw = nil
        return
    end

    local char = LocalPlayer.Character
    if not char then
        return
    end
    local hum = char:FindFirstChildOfClass("Humanoid")
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hum or not hrp then
        was_jumping = false
        is_boosting = false
        bhop_speed = 0
        last_cam_yaw = nil
        return
    end

    local state = hum:GetState()
    local jumping = (state == Enum.HumanoidStateType.Jumping)
    local freefall = (state == Enum.HumanoidStateType.Freefall)
    local airborne = jumping or freefall

    if boost_strafe_on or boost_auto_strafe_on then
        bhop_speed = 0

        if jumping and not was_jumping then
            local dir = hum.MoveDirection
            if dir.Magnitude < 0.1 then
                dir = hrp.CFrame.LookVector
            end
            dir = Vector3.new(dir.X, 0, dir.Z)
            if dir.Magnitude > 0 then
                dir = dir.Unit
                local v = hrp.AssemblyLinearVelocity
                hrp.AssemblyLinearVelocity = Vector3.new(dir.X * boost_value, v.Y, dir.Z * boost_value)
                is_boosting = true
            end
        end

        if is_boosting and airborne then
            if boost_auto_strafe_on then
                local yaw = cam_yaw()
                if yaw and last_cam_yaw then
                    local delta = yaw - last_cam_yaw
                    while delta > math.pi do
                        delta = delta - math.pi * 2
                    end
                    while delta < -math.pi do
                        delta = delta + math.pi * 2
                    end
                    if math.abs(delta) > 0.0005 then
                        local v = hrp.AssemblyLinearVelocity
                        local xz = Vector3.new(v.X, 0, v.Z)
                        if xz.Magnitude > 1 then
                            local rotated = CFrame.fromEulerAnglesYXZ(0, delta, 0) * xz
                            hrp.AssemblyLinearVelocity = Vector3.new(rotated.X, v.Y, rotated.Z)
                        end
                    end
                end
            end

            local dir = hum.MoveDirection
            if dir.Magnitude > 0.1 then
                dir = Vector3.new(dir.X, 0, dir.Z).Unit
                local v = hrp.AssemblyLinearVelocity
                local current_xz = Vector3.new(v.X, 0, v.Z)
                local target = dir * boost_value
                local new_xz = current_xz:Lerp(target, 0.35)
                hrp.AssemblyLinearVelocity = Vector3.new(new_xz.X, v.Y, new_xz.Z)
            elseif boost_auto_strafe_on then
                local v = hrp.AssemblyLinearVelocity
                local xz = Vector3.new(v.X, 0, v.Z)
                if xz.Magnitude > 0.1 and xz.Magnitude < boost_value then
                    local keep = xz.Unit * boost_value
                    hrp.AssemblyLinearVelocity = Vector3.new(keep.X, v.Y, keep.Z)
                end
            end
        end

        if not airborne then
            is_boosting = false
            if jump_is_held() then
                hum.Jump = true
            end
        end
    else
        local base = math.max(hum.WalkSpeed, 16)
        local cap = math.max(boost_value, base)
        local step = math.max(boost_value * 0.2, 4)
        if bhop_speed < base then
            bhop_speed = base
        end

        if jumping and not was_jumping then
            bhop_speed = math.min(bhop_speed + step, cap)
            local v = hrp.AssemblyLinearVelocity
            local xz = Vector3.new(v.X, 0, v.Z)
            local dir
            if xz.Magnitude > 0.1 then
                dir = xz.Unit
            else
                local md = hum.MoveDirection
                if md.Magnitude > 0.1 then
                    dir = Vector3.new(md.X, 0, md.Z).Unit
                else
                    local lv = hrp.CFrame.LookVector
                    dir = Vector3.new(lv.X, 0, lv.Z)
                    if dir.Magnitude > 0 then
                        dir = dir.Unit
                    else
                        dir = Vector3.new(0, 0, 0)
                    end
                end
            end
            if dir.Magnitude > 0 then
                hrp.AssemblyLinearVelocity = Vector3.new(dir.X * bhop_speed, v.Y, dir.Z * bhop_speed)
                is_boosting = true
            end
        end

        if airborne and is_boosting then
            local v = hrp.AssemblyLinearVelocity
            local xz = Vector3.new(v.X, 0, v.Z)
            local md = hum.MoveDirection
            local dir
            if md.Magnitude > 0.1 then
                dir = Vector3.new(md.X, 0, md.Z).Unit
            elseif xz.Magnitude > 0.1 then
                dir = xz.Unit
            end
            if dir then
                local speed = math.max(xz.Magnitude, bhop_speed)
                hrp.AssemblyLinearVelocity = Vector3.new(dir.X * speed, v.Y, dir.Z * speed)
            end
        end

        if not airborne then
            is_boosting = false
            if jump_is_held() then
                hum.Jump = true
            else
                bhop_speed = 0
            end
        end
    end

    last_cam_yaw = cam_yaw()
    was_jumping = jumping
end)

local fling_bypass_vel = false
local fling_round_mod = nil

local AntiFlingEnabled = false
local af_cache = {}
local af_reg = {}
local af_step = nil

local function af_kill(p)
    if af_cache[p] == nil then
        af_cache[p] = p.CanCollide
    end
    if p.CanCollide then
        p.CanCollide = false
    end
end

local function af_unregister(model)
    local entry = af_reg[model]
    if not entry then
        return
    end
    af_reg[model] = nil
    for i = 1, #entry.conns do
        pcall(function()
            entry.conns[i]:Disconnect()
        end)
    end
    for p in pairs(entry.parts) do
        local v = af_cache[p]
        af_cache[p] = nil
        if v ~= nil and p.Parent then
            pcall(function()
                p.CanCollide = v
            end)
        end
    end
end

local function af_register(model)
    if not AntiFlingEnabled or not model then
        return
    end
    if af_reg[model] or model == LocalPlayer.Character then
        return
    end
    if not model:FindFirstChildOfClass("Humanoid") then
        return
    end
    local entry = { parts = {}, conns = {} }
    af_reg[model] = entry
    local function add(d)
        if d:IsA("BasePart") and not entry.parts[d] then
            entry.parts[d] = true
            pcall(af_kill, d)
        end
    end
    for _, d in ipairs(model:GetDescendants()) do
        pcall(add, d)
    end
    entry.conns[#entry.conns + 1] = model.DescendantAdded:Connect(function(d)
        if AntiFlingEnabled then
            pcall(add, d)
        end
    end)
    entry.conns[#entry.conns + 1] = model.AncestryChanged:Connect(function(_, parent)
        if not parent then
            af_unregister(model)
        end
    end)
end

local function af_scan()
    for _, pl in ipairs(Players:GetPlayers()) do
        if pl ~= LocalPlayer and pl.Character then
            af_register(pl.Character)
        end
    end
end

local function setAntiFling(on)
    AntiFlingEnabled = on
    if on then
        af_scan()
        for _, pl in ipairs(Players:GetPlayers()) do
            if pl ~= LocalPlayer then
                pl.CharacterAdded:Connect(function(c)
                    if AntiFlingEnabled then
                        af_register(c)
                    end
                end)
            end
        end
        Players.PlayerAdded:Connect(function(pl)
            pl.CharacterAdded:Connect(function(c)
                if AntiFlingEnabled then
                    af_register(c)
                end
            end)
        end)
        if not af_step then
            af_step = RunService.Heartbeat:Connect(function()
                if not AntiFlingEnabled then
                    return
                end
                for model, entry in pairs(af_reg) do
                    if not model.Parent then
                        af_unregister(model)
                    else
                        for p in pairs(entry.parts) do
                            if p.Parent and p.CanCollide then
                                p.CanCollide = false
                            end
                        end
                    end
                end
            end)
        end
    else
        for model in pairs(af_reg) do
            af_unregister(model)
        end
        for p, v in pairs(af_cache) do
            if p and p.Parent and v ~= nil then
                pcall(function()
                    p.CanCollide = v
                end)
            end
        end
        af_cache = {}
    end
end

local function fling_hrp()
    local c = LocalPlayer.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function fling_data()
    if not fling_round_mod then
        local ok, m = pcall(function()
            return require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("CurrentRoundClient"))
        end)
        if ok and type(m) == "table" then
            fling_round_mod = m
        end
    end
    return fling_round_mod and fling_round_mod.PlayerData
end

local function fling_role(role)
    local d = fling_data()
    if type(d) ~= "table" then
        return nil
    end
    for name, info in pairs(d) do
        if type(info) == "table" and not info.Dead then
            if info.Role == role or (role == "Sheriff" and info.Role == "Hero") then
                local p = Players:FindFirstChild(name)
                if p and p ~= LocalPlayer then
                    return p
                end
            end
        end
    end
    return nil
end

local function do_fling(tp)
    if not tp or not tp.Character then
        return
    end
    local hrp = fling_hrp()
    local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
    if not hrp then
        return
    end
    local tc = tp.Character
    local thrp = tc:FindFirstChild("HumanoidRootPart") or tc:FindFirstChild("Head")
    local th = tc:FindFirstChildOfClass("Humanoid")
    if not thrp then
        return
    end
    getgenv().FLING_ACTIVE = (getgenv().FLING_ACTIVE or 0) + 1
    if hrp.AssemblyLinearVelocity.Magnitude < 50 then
        getgenv().OldPos = hrp.CFrame
    end
    if th and th.Sit then
        getgenv().FLING_ACTIVE = math.max(0, (getgenv().FLING_ACTIVE or 1) - 1)
        return
    end
    local camera = Workspace.CurrentCamera
    local old_fdh = Workspace.FallenPartsDestroyHeight
    if thrp then
        camera.CameraSubject = thrp
    elseif th then
        camera.CameraSubject = th
    end
    pcall(function()
        Workspace.FallenPartsDestroyHeight = 0 / 0
    end)
    local bv = Instance.new("BodyVelocity")
    bv.Parent = hrp
    bv.Velocity = Vector3.new(0, 0, 0)
    bv.MaxForce = Vector3.new(9e9, 9e9, 9e9)
    local se = hum and hum:GetStateEnabled(Enum.HumanoidStateType.Seated)
    if hum then
        hum:SetStateEnabled(Enum.HumanoidStateType.Seated, false)
    end
    local tw = 2
    local tm = tick()
    local ang = 0
    repeat
        if hrp and th and thrp and thrp.Parent then
            ang = ang + 100
            pcall(function()
                hrp.CFrame = CFrame.new(thrp.Position) * CFrame.new(0, 1.5, 0) * CFrame.Angles(math.rad(ang), 0, 0)
                hrp.AssemblyLinearVelocity = Vector3.new(9e7, 9e7 * 10, 9e7)
                hrp.AssemblyAngularVelocity = Vector3.new(9e8, 9e8, 9e8)
            end)
            task.wait()
            pcall(function()
                hrp.CFrame = CFrame.new(thrp.Position) * CFrame.new(0, -1.5, 0) * CFrame.Angles(math.rad(ang), 0, 0)
                hrp.AssemblyLinearVelocity = Vector3.new(9e7, 9e7 * 10, 9e7)
                hrp.AssemblyAngularVelocity = Vector3.new(9e8, 9e8, 9e8)
            end)
            task.wait()
        else
            break
        end
    until tm + tw < tick()
    if bv then
        bv:Destroy()
    end
    if hum and se ~= nil then
        hum:SetStateEnabled(Enum.HumanoidStateType.Seated, se)
    end
    if hum then
        camera.CameraSubject = hum
    end
    if getgenv().OldPos then
        local tries = 0
        repeat
            tries = tries + 1
            pcall(function()
                hrp.CFrame = getgenv().OldPos * CFrame.new(0, 0.5, 0)
                if hum then
                    hum:ChangeState(Enum.HumanoidStateType.GettingUp)
                end
                for _, part in ipairs(LocalPlayer.Character:GetChildren()) do
                    if part:IsA("BasePart") then
                        part.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
                        part.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
                    end
                end
            end)
            task.wait()
        until tries > 30 or (hrp.Position - getgenv().OldPos.Position).Magnitude < 25
        pcall(function()
            Workspace.FallenPartsDestroyHeight = old_fdh
        end)
    end
    getgenv().FLING_ACTIVE = math.max(0, (getgenv().FLING_ACTIVE or 1) - 1)
end

local function hasGun()
    local char = LocalPlayer.Character
    return LocalPlayer.Backpack:FindFirstChild("Gun") or (char and char:FindFirstChild("Gun"))
end

local function getPlayerStatus()
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not char or not hum or hum.Health <= 0 then
        return "Spectate"
    end

    local entry = roleTable and roleTable[LocalPlayer.Name]
    if entry then
        if entry.Dead then
            return "Spectate"
        end
        if entry.Role == "Murderer" or entry.Role == "Sheriff" or entry.Role == "Innocent" or entry.Role == "Hero" then
            return "Match"
        end
    end

    local m = nil
    pcall(function()
        m = require(ReplicatedStorage:FindFirstChild("Modules") and ReplicatedStorage.Modules:FindFirstChild("CurrentRoundClient"))
    end)
    if type(m) == "table" and type(m.PlayerData) == "table" then
        local me = m.PlayerData[LocalPlayer.Name]
        if me then
            if me.Dead then return "Spectate" end
            if me.Role == "Murderer" or me.Role == "Sheriff" or me.Role == "Innocent" or me.Role == "Hero" then
                return "Match"
            end
        end
    end

    if Workspace:FindFirstChild("GunDrop", true) then
        return "Match"
    end

    return "Spectate"
end

local function refreshPlayerStatus()
    PlayerStatus = getPlayerStatus()
    if statusLabelRef then
        pcall(function()
            if statusLabelRef.SetDesc then
                statusLabelRef:SetDesc(PlayerStatus)
            elseif statusLabelRef.Set then
                statusLabelRef:Set(PlayerStatus)
            end
        end)
    end
    return PlayerStatus
end

local function GrabGun(force)
    if not force then
        refreshPlayerStatus()
        if PlayerStatus ~= "Match" then
            return
        end
    end
    if isGrabbing then return end
    if hasGun() then return end

    isGrabbing = true

    local character = LocalPlayer.Character
    if not character then
        isGrabbing = false
        return
    end

    local root = character:FindFirstChild("HumanoidRootPart")
    if not root then
        isGrabbing = false
        return
    end

    local maxAttempts = 90
    local attempts = 0
    local originalCFrame = root.CFrame

    local function pullDrop(gunDrop)
        local target = root.CFrame * CFrame.new(0, 1.2, 0)
        if gunDrop:IsA("BasePart") then
            gunDrop.Anchored = false
            gunDrop.CanCollide = false
            gunDrop.AssemblyLinearVelocity = Vector3.zero
            gunDrop.AssemblyAngularVelocity = Vector3.zero
            gunDrop.CFrame = target
            gunDrop.CFrame = target
        else
            local part = gunDrop:FindFirstChild("Handle")
                or gunDrop:FindFirstChildWhichIsA("BasePart")
                or gunDrop.PrimaryPart
            if part and part:IsA("BasePart") then
                part.Anchored = false
                part.CanCollide = false
                part.AssemblyLinearVelocity = Vector3.zero
                part.AssemblyAngularVelocity = Vector3.zero
                part.CFrame = target
                part.CFrame = target
            else
                pcall(function() gunDrop:PivotTo(target) end)
            end
        end
    end

    while attempts < maxAttempts and not hasGun() do
        local gunDrop = Workspace:FindFirstChild("GunDrop", true)
        if gunDrop then
            local ok = pcall(pullDrop, gunDrop)
            if not ok then
                pcall(function()
                    local cf = gunDrop:IsA("BasePart") and gunDrop.CFrame or gunDrop:GetPivot()
                    root.CFrame = cf
                    task.wait()
                    root.CFrame = originalCFrame
                end)
            end
        end
        if hasGun() then break end
        task.wait()
        attempts = attempts + 1
    end

    if hasGun() and SuccessNotify then
        notify("GrabGun", "Gun successfully grabbed!")
    end

    isGrabbing = false
end

local function onGunDropDetected(gunDrop)
    if GunNotify then
        notify("Gun Dropped", "GunDrop appeared on the map!")
    end
    if AutoGrab then
        refreshPlayerStatus()
        if PlayerStatus == "Match" then
            task.spawn(GrabGun)
        end
    end
end

local function setupGunDropListener(parent)
    parent.ChildAdded:Connect(function(child)
        if child.Name == "GunDrop" then
            task.wait(0.1)
            onGunDropDetected(child)
        end
        if child:IsA("Model") or child:IsA("Folder") then
            setupGunDropListener(child)
        end
    end)
    for _, child in ipairs(parent:GetChildren()) do
        if child:IsA("Model") or child:IsA("Folder") then
            setupGunDropListener(child)
        end
    end
end

setupGunDropListener(Workspace)

Workspace.ChildAdded:Connect(function(child)
    if child:IsA("Model") or child:IsA("Folder") then
        setupGunDropListener(child)
    end
    if child.Name == "GunDrop" then
        task.wait(0.1)
        onGunDropDetected(child)
    end
end)

task.spawn(function()
    task.wait(1)
    local existing = Workspace:FindFirstChild("GunDrop", true)
    if existing then
        onGunDropDetected(existing)
    end
end)

local function applyMovement(char)
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum then
        hum.WalkSpeed = WalkSpeedValue
        hum.JumpPower = JumpPowerValue
        hum.UseJumpPower = true
    end
end

LocalPlayer.CharacterAdded:Connect(function(char)
    root = char:WaitForChild("HumanoidRootPart", 2)
    humanoid = char:WaitForChild("Humanoid", 2)
    task.wait(0.3)
    applyMovement(char)
end)

if LocalPlayer.Character then
    root = LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    humanoid = LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
    applyMovement(LocalPlayer.Character)
end

UserInputService.JumpRequest:Connect(function()
    if not InfJump then return end
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum then
        hum:ChangeState(Enum.HumanoidStateType.Jumping)
    end
end)

RunService.Heartbeat:Connect(function()
    if SpeedGlitch and root and humanoid and humanoid.FloorMaterial == Enum.Material.Air then
        local dir = humanoid.MoveDirection
        if dir.Magnitude > 0.05 then
            local vel = root.AssemblyLinearVelocity
            root.AssemblyLinearVelocity = Vector3.new(dir.X * SpeedGlitchValue, vel.Y, dir.Z * SpeedGlitchValue)
        end
    end
end)

local CoreGui = game:GetService("CoreGui")
local espGuiParent = (gethui and gethui()) or CoreGui

local espSettings = {
    MurdererColor = Color3.fromRGB(255, 80, 80),
    SheriffColor = Color3.fromRGB(80, 140, 255),
    HeroColor = Color3.fromRGB(255, 215, 0),
    InnocentColor = Color3.fromRGB(170, 255, 170),
    UnknownColor = Color3.fromRGB(190, 190, 190),
    GunColor = Color3.fromRGB(70, 130, 255),
    NameColor = Color3.fromRGB(255, 255, 255),
    ESP = { Enabled = false, Everyone = false, Murderer = true, Sheriff = true, Innocent = true, Gun = true },
    Outline = { Enabled = false, Everyone = false, Murderer = false, Sheriff = false, Innocent = false, Gun = false },
    Chams = { Enabled = false, Everyone = false, Murderer = true, Sheriff = true, Innocent = true, Gun = true },
    Tracers = { Enabled = false, Everyone = false, Murderer = true, Sheriff = true, Innocent = true, Gun = true },
    Box = { Enabled = false, Everyone = false, Murderer = false, Sheriff = false, Innocent = false, Gun = false },
}

local roleTable = {}
local currentMurderer, currentSheriff, currentHero = nil, nil, nil
local espObjects = {}
local highlightObjects = {}
local gunEspObjects = {}
local gunHighlightObjects = {}
local allPlayersCache = {}
local GetPlayerData = nil
local ESPMaster = false

local function hasDrawing()
    return type(Drawing) == "table" and type(Drawing.new) == "function"
end

local function getRole(plr)
    if not plr then return "Unknown" end
    local entry = roleTable[plr.Name]
    return (entry and entry.Role) and tostring(entry.Role) or "Unknown"
end

local function isDead(plr)
    if not plr then return true end
    local entry = roleTable[plr.Name]
    if entry and entry.Dead == true then return true end
    return false
end

local function getEspRoot(plr)
    local char = plr and plr.Character
    if not char then return nil, nil end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if hrp then return hrp, char end
    local head = char:FindFirstChild("Head")
    if head then return head, char end
    local part = char:FindFirstChildWhichIsA("BasePart")
    if part then return part, char end
    return nil, char
end

local function getDisplayColor(role)
    if role == "Murderer" then return espSettings.MurdererColor end
    if role == "Sheriff" then return espSettings.SheriffColor end
    if role == "Hero" then return espSettings.HeroColor end
    if role == "Innocent" then return espSettings.InnocentColor end
    return espSettings.UnknownColor
end

local function shouldShow(category, role)
    local s = espSettings[category]
    if not s or not s.Enabled then return false end
    if s.Everyone then return true end
    if role == "Murderer" and s.Murderer then return true end
    if (role == "Sheriff" or role == "Hero") and s.Sheriff then return true end
    if role == "Innocent" and s.Innocent then return true end
    return false
end

local function shouldShowGun(category)
    local s = espSettings[category]
    return s and s.Enabled and s.Gun
end

local function updateCachedRoles()
    currentMurderer, currentSheriff, currentHero = nil, nil, nil
    allPlayersCache = Players:GetPlayers()
    for _, plr in ipairs(allPlayersCache) do
        local role = getRole(plr)
        if not isDead(plr) then
            if role == "Murderer" then currentMurderer = plr
            elseif role == "Sheriff" then currentSheriff = plr
            elseif role == "Hero" then currentHero = plr end
        end
    end
end

local function refreshRoles()
    if not GetPlayerData or not GetPlayerData.Parent then
        GetPlayerData = ReplicatedStorage:FindFirstChild("GetPlayerData", true)
    end
    if GetPlayerData then
        local ok, result = pcall(function()
            return GetPlayerData:InvokeServer()
        end)
        if ok and typeof(result) == "table" then
            roleTable = result
        end
    end
    updateCachedRoles()
end

local function createESP(plr)
    if espObjects[plr] then return end
    local box = {}
    if hasDrawing() then
        for i = 1, 4 do
            local line = Drawing.new("Line")
            line.Visible = false
            line.Color = Color3.fromRGB(255, 255, 255)
            line.Thickness = 1
            line.Transparency = 1
            box[i] = line
        end
    end

    local billboard = Instance.new("BillboardGui")
    billboard.Size = UDim2.new(0, 220, 0, 60)
    billboard.StudsOffset = Vector3.new(0, 2.2, 0)
    billboard.AlwaysOnTop = true
    billboard.LightInfluence = 0
    billboard.Enabled = false
    billboard.Parent = espGuiParent

    local nameLabel = Instance.new("TextLabel")
    nameLabel.BackgroundTransparency = 1
    nameLabel.TextStrokeTransparency = 0
    nameLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
    nameLabel.Font = Enum.Font.Code
    nameLabel.TextSize = 14
    nameLabel.TextColor3 = espSettings.NameColor
    nameLabel.Size = UDim2.new(1, 0, 0.4, 0)
    nameLabel.Parent = billboard

    local roleLabel = Instance.new("TextLabel")
    roleLabel.BackgroundTransparency = 1
    roleLabel.TextStrokeTransparency = 0
    roleLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
    roleLabel.Font = Enum.Font.Code
    roleLabel.TextSize = 13
    roleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
    roleLabel.Size = UDim2.new(1, 0, 0.3, 0)
    roleLabel.Position = UDim2.new(0, 0, 0.4, 0)
    roleLabel.Parent = billboard

    local distLabel = Instance.new("TextLabel")
    distLabel.BackgroundTransparency = 1
    distLabel.TextStrokeTransparency = 0
    distLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
    distLabel.Font = Enum.Font.Ubuntu
    distLabel.TextSize = 12
    distLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
    distLabel.Size = UDim2.new(1, 0, 0.3, 0)
    distLabel.Position = UDim2.new(0, 0, 0.7, 0)
    distLabel.Parent = billboard

    local tracer = nil
    if hasDrawing() then
        tracer = Drawing.new("Line")
        tracer.Visible = false
        tracer.Color = Color3.fromRGB(255, 255, 255)
        tracer.Thickness = 1
        tracer.Transparency = 1
    end

    espObjects[plr] = {
        box = box,
        billboard = billboard,
        nameLabel = nameLabel,
        roleLabel = roleLabel,
        distLabel = distLabel,
        tracer = tracer,
    }
end

local function removeESP(plr)
    local obj = espObjects[plr]
    if not obj then return end
    for _, line in pairs(obj.box) do
        pcall(function() line:Remove() end)
    end
    if obj.tracer then pcall(function() obj.tracer:Remove() end) end
    if obj.billboard then pcall(function() obj.billboard:Destroy() end) end
    espObjects[plr] = nil
end

local BODY_PARTS = {
    "HumanoidRootPart", "Head", "Torso", "UpperTorso", "LowerTorso",
    "Left Arm", "Right Arm", "Left Leg", "Right Leg",
    "LeftUpperArm", "RightUpperArm", "LeftLowerArm", "RightLowerArm",
    "LeftHand", "RightHand", "LeftUpperLeg", "RightUpperLeg",
    "LeftLowerLeg", "RightLowerLeg", "LeftFoot", "RightFoot"
}

local function lightUninvis(char)
    if not char then return end
    for i = 1, #BODY_PARTS do
        local p = char:FindFirstChild(BODY_PARTS[i])
        if p and p:IsA("BasePart") then
            pcall(function()
                if p.LocalTransparencyModifier > 0.05 then
                    p.LocalTransparencyModifier = 0
                end
            end)
        end
    end
end

local function applyHighlight(plr, color, chams, outline)
    local char = plr.Character
    if not char then return end
    if chams then
        lightUninvis(char)
    end
    local hl = highlightObjects[plr]
    if not hl or not hl.Parent then
        if hl then pcall(function() hl:Destroy() end) end
        hl = Instance.new("Highlight")
        hl.Name = "HubESP_" .. plr.Name
        hl.Adornee = char
        hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        hl.Parent = espGuiParent
        highlightObjects[plr] = hl
    end
    hl.Adornee = char
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    if chams and outline then
        hl.FillColor = color
        hl.FillTransparency = 0.35
        hl.OutlineColor = color
        hl.OutlineTransparency = 0
    elseif chams then
        hl.FillColor = color
        hl.FillTransparency = 0.35
        hl.OutlineTransparency = 1
    elseif outline then
        hl.FillTransparency = 1
        hl.OutlineColor = color
        hl.OutlineTransparency = 0
    end
    hl.Enabled = true
end

local function removeHighlight(plr)
    local hl = highlightObjects[plr]
    if not hl then return end
    pcall(function() hl.Adornee = nil end)
    pcall(function() hl.Enabled = false end)
    pcall(function() hl:Destroy() end)
    highlightObjects[plr] = nil
end

local function hideDrawings(obj)
    if not obj then return end
    if obj.box then
        for _, line in pairs(obj.box) do
            if line then line.Visible = false end
        end
    end
    if obj.tracer then obj.tracer.Visible = false end
    if obj.billboard then obj.billboard.Enabled = false end
end

local function createGunESP(drop)
    if gunEspObjects[drop] then return end
    local box = {}
    if hasDrawing() then
        for i = 1, 4 do
            local line = Drawing.new("Line")
            line.Visible = false
            line.Color = espSettings.GunColor
            line.Thickness = 1
            line.Transparency = 1
            box[i] = line
        end
    end

    local billboard = Instance.new("BillboardGui")
    billboard.Size = UDim2.new(0, 160, 0, 45)
    billboard.StudsOffset = Vector3.new(0, 2.8, 0)
    billboard.AlwaysOnTop = true
    billboard.LightInfluence = 0
    billboard.Enabled = false
    billboard.Parent = espGuiParent

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.TextStrokeTransparency = 0
    label.TextStrokeColor3 = Color3.new(0, 0, 0)
    label.Font = Enum.Font.Code
    label.TextSize = 14
    label.TextColor3 = Color3.fromRGB(255, 220, 0)
    label.Text = "Gun"
    label.Size = UDim2.new(1, 0, 0.5, 0)
    label.Parent = billboard

    local distLabel = Instance.new("TextLabel")
    distLabel.BackgroundTransparency = 1
    distLabel.TextStrokeTransparency = 0
    distLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
    distLabel.Font = Enum.Font.Code
    distLabel.TextSize = 12
    distLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
    distLabel.Size = UDim2.new(1, 0, 0.5, 0)
    distLabel.Position = UDim2.new(0, 0, 0.5, 0)
    distLabel.Parent = billboard

    local tracer = nil
    if hasDrawing() then
        tracer = Drawing.new("Line")
        tracer.Visible = false
        tracer.Color = espSettings.GunColor
        tracer.Thickness = 1
        tracer.Transparency = 1
    end

    gunEspObjects[drop] = {
        box = box,
        billboard = billboard,
        label = label,
        distLabel = distLabel,
        tracer = tracer,
    }
end

local function removeGunESP(drop)
    local obj = gunEspObjects[drop]
    if not obj then return end
    for _, line in pairs(obj.box) do
        pcall(function() line:Remove() end)
    end
    if obj.tracer then pcall(function() obj.tracer:Remove() end) end
    if obj.billboard then pcall(function() obj.billboard:Destroy() end) end
    gunEspObjects[drop] = nil
end

local function applyGunHighlight(drop, chams, outline)
    local part = drop:IsA("BasePart") and drop or drop:FindFirstChildWhichIsA("BasePart") or drop.PrimaryPart
    if not part then return end
    local hl = gunHighlightObjects[drop]
    if not hl then
        hl = Instance.new("Highlight")
        hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        hl.Parent = espGuiParent
        gunHighlightObjects[drop] = hl
    end
    hl.Adornee = drop:IsA("Model") and drop or part
    local color = espSettings.GunColor
    if chams and outline then
        hl.FillColor = color
        hl.FillTransparency = 0.4
        hl.OutlineColor = color
        hl.OutlineTransparency = 0
    elseif chams then
        hl.FillColor = color
        hl.FillTransparency = 0.4
        hl.OutlineTransparency = 1
    elseif outline then
        hl.FillTransparency = 1
        hl.OutlineColor = color
        hl.OutlineTransparency = 0
    end
    hl.Enabled = true
end

local function removeGunHighlight(drop)
    local hl = gunHighlightObjects[drop]
    if not hl then return end
    pcall(function() hl:Destroy() end)
    gunHighlightObjects[drop] = nil
end

local function isValidGunDrop(obj)
    if not obj or not obj.Parent then return false end
    if obj.Name ~= "GunDrop" then return false end
    return obj:IsA("BasePart") or obj:IsA("Model")
end

local function registerGunDrop(obj)
    if not isValidGunDrop(obj) then return end
    pcall(createGunESP, obj)
    pcall(function()
        obj.AncestryChanged:Connect(function(_, parent)
            if not parent then
                pcall(removeGunESP, obj)
                pcall(removeGunHighlight, obj)
            end
        end)
    end)
end

local function clearAllESP()
    for plr in pairs(espObjects) do
        removeESP(plr)
        removeHighlight(plr)
    end
    for drop in pairs(gunEspObjects) do
        removeGunESP(drop)
        removeGunHighlight(drop)
    end
end

local function updateESP()
    if not ESPMaster then return end

    local myChar = LocalPlayer.Character
    local myHRP = myChar and myChar:FindFirstChild("HumanoidRootPart")
    local viewport = Camera.ViewportSize

    for _, plr in ipairs(allPlayersCache) do
        if plr ~= LocalPlayer then
            if not espObjects[plr] then
                createESP(plr)
            end
            local obj = espObjects[plr]
            if not obj then
                createESP(plr)
                obj = espObjects[plr]
            end
            if not obj then continue end
            local root, char = getEspRoot(plr)
            local role = getRole(plr)
            local dead = isDead(plr)

            if not root then
                hideDrawings(obj)
                removeHighlight(plr)
            else
                local color = dead and espSettings.UnknownColor or getDisplayColor(role)
                local screenPos, onScreen = Camera:WorldToViewportPoint(root.Position)
                local dist = myHRP and (myHRP.Position - root.Position).Magnitude or 0
                if dist < 0.001 then dist = 0.001 end

                local showBox = onScreen and shouldShow("Box", role)
                local showName = onScreen and shouldShow("ESP", role)
                local showTracer = onScreen and shouldShow("Tracers", role)
                local showChams = shouldShow("Chams", role)
                local showOutline = shouldShow("Outline", role)

                if not (showBox or showName or showTracer or showChams or showOutline) then
                    hideDrawings(obj)
                    removeHighlight(plr)
                else
                    if showBox and #obj.box >= 4 then
                        local head = char and char:FindFirstChild("Head")
                        local topPos = head and Camera:WorldToViewportPoint(head.Position + Vector3.new(0, 0.5, 0)) or screenPos
                        local botPos = Camera:WorldToViewportPoint(root.Position - Vector3.new(0, 3, 0))
                        local w = 2000 / dist
                        local tl = Vector2.new(screenPos.X - w / 2, topPos.Y)
                        local tr = Vector2.new(screenPos.X + w / 2, topPos.Y)
                        local bl = Vector2.new(screenPos.X - w / 2, botPos.Y)
                        local br = Vector2.new(screenPos.X + w / 2, botPos.Y)
                        obj.box[1].From, obj.box[1].To, obj.box[1].Color, obj.box[1].Visible = tl, tr, color, true
                        obj.box[2].From, obj.box[2].To, obj.box[2].Color, obj.box[2].Visible = bl, br, color, true
                        obj.box[3].From, obj.box[3].To, obj.box[3].Color, obj.box[3].Visible = tl, bl, color, true
                        obj.box[4].From, obj.box[4].To, obj.box[4].Color, obj.box[4].Visible = tr, br, color, true
                    else
                        for _, line in pairs(obj.box) do line.Visible = false end
                    end

                    do
                        local invis = false
                        if char then
                            local hp = char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Head")
                            if hp and hp:IsA("BasePart") then
                                local lt = 0
                                pcall(function() lt = hp.LocalTransparencyModifier end)
                                if lt >= 0.9 then invis = true end
                            end
                        end
                        local showTag = showName or (invis and shouldShow("Chams", role))
                        if showTag and obj.billboard then
                            local head = char and char:FindFirstChild("Head")
                            obj.billboard.Adornee = head or root or char
                            obj.billboard.Enabled = true
                            obj.nameLabel.Text = invis and (plr.Name .. " [INVIS]") or plr.Name
                            obj.nameLabel.TextColor3 = color
                            obj.roleLabel.Text = dead and "[DEAD]" or ("[" .. role:upper() .. "]")
                            obj.roleLabel.TextColor3 = color
                            obj.distLabel.Text = string.format("[%d studs]", math.floor(dist))
                        elseif obj.billboard then
                            obj.billboard.Enabled = false
                        end
                    end

                    if showTracer and obj.tracer then
                        obj.tracer.From = Vector2.new(viewport.X / 2, viewport.Y)
                        obj.tracer.To = Vector2.new(screenPos.X, screenPos.Y)
                        obj.tracer.Color = color
                        obj.tracer.Visible = true
                    elseif obj.tracer then
                        obj.tracer.Visible = false
                    end

                    if showChams or showOutline then
                        applyHighlight(plr, color, showChams, showOutline)
                    else
                        removeHighlight(plr)
                    end

                end
            end
        end
    end


    for drop, obj in pairs(gunEspObjects) do
        if not drop or not drop.Parent then
            removeGunESP(drop)
            removeGunHighlight(drop)
        else
            local part = drop:IsA("BasePart") and drop or drop:FindFirstChildWhichIsA("BasePart") or drop.PrimaryPart
            if not part then
                hideDrawings(obj)
                removeGunHighlight(drop)
            else
                local screenPos, onScreen = Camera:WorldToViewportPoint(part.Position)
                local dist = myHRP and (myHRP.Position - part.Position).Magnitude or 0
                if dist < 0.001 then dist = 0.001 end

                local showBox = onScreen and shouldShowGun("Box")
                local showName = onScreen and shouldShowGun("ESP")
                local showTracer = onScreen and shouldShowGun("Tracers")
                local showChams = shouldShowGun("Chams")
                local showOutline = shouldShowGun("Outline")

                if not (showBox or showName or showTracer or showChams or showOutline) then
                    hideDrawings(obj)
                    removeGunHighlight(drop)
                else
                    if showBox and #obj.box >= 4 then
                        local top = Camera:WorldToViewportPoint(part.Position + Vector3.new(0, 2, 0))
                        local bot = Camera:WorldToViewportPoint(part.Position - Vector3.new(0, 2, 0))
                        local w = 1200 / dist
                        local tl = Vector2.new(screenPos.X - w / 2, top.Y)
                        local tr = Vector2.new(screenPos.X + w / 2, top.Y)
                        local bl = Vector2.new(screenPos.X - w / 2, bot.Y)
                        local br = Vector2.new(screenPos.X + w / 2, bot.Y)
                        local gc = espSettings.GunColor
                        obj.box[1].From, obj.box[1].To, obj.box[1].Color, obj.box[1].Visible = tl, tr, gc, true
                        obj.box[2].From, obj.box[2].To, obj.box[2].Color, obj.box[2].Visible = bl, br, gc, true
                        obj.box[3].From, obj.box[3].To, obj.box[3].Color, obj.box[3].Visible = tl, bl, gc, true
                        obj.box[4].From, obj.box[4].To, obj.box[4].Color, obj.box[4].Visible = tr, br, gc, true
                    else
                        for _, line in pairs(obj.box) do line.Visible = false end
                    end

                    if showName and obj.billboard then
                        obj.billboard.Adornee = part
                        obj.billboard.Enabled = true
                        obj.label.Text = "Gun"
                        obj.label.TextColor3 = Color3.fromRGB(255, 220, 0)
                        obj.distLabel.Text = string.format("[%d studs]", math.floor(dist))
                    elseif obj.billboard then
                        obj.billboard.Enabled = false
                    end

                    if showTracer and obj.tracer then
                        obj.tracer.From = Vector2.new(viewport.X / 2, viewport.Y)
                        obj.tracer.To = Vector2.new(screenPos.X, screenPos.Y)
                        obj.tracer.Color = espSettings.GunColor
                        obj.tracer.Visible = true
                    elseif obj.tracer then
                        obj.tracer.Visible = false
                    end

                    if showChams or showOutline then
                        applyGunHighlight(drop, showChams, showOutline)
                    else
                        removeGunHighlight(drop)
                    end
                end
            end
        end
    end
end

task.spawn(function()
    repeat
        GetPlayerData = ReplicatedStorage:FindFirstChild("GetPlayerData", true)
        task.wait(1)
    until GetPlayerData
    refreshRoles()
end)

task.spawn(function()
    while task.wait(2) do
        if ESPMaster then
            refreshRoles()
        end
    end
end)

pcall(function()
    for _, v in ipairs(ReplicatedStorage:GetDescendants()) do
        if v.Name == "PlayerDataChanged" and v:IsA("RemoteEvent") then
            v.OnClientEvent:Connect(function(data)
                if typeof(data) == "table" then
                    roleTable = data
                    updateCachedRoles()
                else
                    refreshRoles()
                end
            end)
            break
        end
    end
end)

pcall(function()
    for _, desc in ipairs(Workspace:GetDescendants()) do
        if desc.Name == "GunDrop" then
            pcall(registerGunDrop, desc)
        end
    end
end)

Workspace.DescendantAdded:Connect(function(desc)
    if desc.Name == "GunDrop" then
        task.defer(registerGunDrop, desc)
    end
end)

RunService.RenderStepped:Connect(function()
    local ok, err = pcall(updateESP)
    if not ok then

    end
end)

Players.PlayerRemoving:Connect(function(plr)
    removeESP(plr)
    removeHighlight(plr)
end)

Players.PlayerAdded:Connect(function(plr)
    task.delay(1, function()
        if ESPMaster then
            refreshRoles()
            createESP(plr)
        end
    end)
end)

allPlayersCache = Players:GetPlayers()
for _, plr in ipairs(allPlayersCache) do
    if plr ~= LocalPlayer then
        createESP(plr)
    end
end

local PARTICLE_AURA_DATA = {
    { "starlight", "rbxassetid://134645216613107" },
    { "heavenly", "rbxassetid://139300897520961" },
    { "ribbon", "rbxassetid://132069507632161" },
    { "sakura", "rbxassetid://81755778619404" },
    { "angel", "rbxassetid://97658130917593" },
    { "wind", "rbxassetid://80694081850877" },
    { "flow", "rbxassetid://119913533725648" },
    { "star", "rbxassetid://73754563740680" },
    { "neon", "rbxassetid://18498709246" },
}

local PARTICLE_AURA_NAMES = {}
local particleAuraIdByName = {}

for _, row in ipairs(PARTICLE_AURA_DATA) do
    table.insert(PARTICLE_AURA_NAMES, row[1])
    particleAuraIdByName[row[1]] = row[2]
end

local loadedParticleAuras = {}
local selfAuraParticles = {}
local SelfAuraEnabled = false
local SelfAuraType = "starlight"
local SelfAuraColor = Color3.fromRGB(133, 220, 255)

local function mapCharacterParts(character)
    local parts = {}
    for _, child in ipairs(character:GetChildren()) do
        if child:IsA("BasePart") then
            parts[child.Name] = child
        end
    end
    return parts
end

local function getParticleAuraTemplate(name)
    local cached = loadedParticleAuras[name]
    if cached then return cached end
    local id = particleAuraIdByName[name]
    if not id then return nil end
    local ok, result = pcall(function()
        return game:GetObjects(id)[1]
    end)
    if ok and result then
        loadedParticleAuras[name] = result
        return result
    end
    return nil
end

local function clearSelfAura()
    for _, p in ipairs(selfAuraParticles) do
        if p then p:Destroy() end
    end
    table_clear(selfAuraParticles)
end

local function tintParticleSubtree(rootObj, color)
    if not color or not rootObj then return end
    local seq = ColorSequence.new(color)
    local function tintOne(obj)
        if obj:IsA("ParticleEmitter") or obj:IsA("Beam") or obj:IsA("Trail") then
            obj.Color = seq
        elseif obj:IsA("PointLight") then
            obj.Color = color
        end
    end
    tintOne(rootObj)
    for _, d in ipairs(rootObj:GetDescendants()) do
        tintOne(d)
    end
end

local function setParticleEmittersEnabledInSubtree(rootObj, enabled)
    if not rootObj then return end
    if rootObj:IsA("ParticleEmitter") then
        rootObj.Enabled = enabled
    end
    for _, d in ipairs(rootObj:GetDescendants()) do
        if d:IsA("ParticleEmitter") then
            d.Enabled = enabled
        end
    end
end

local function applyParticleAuraToCharacter(character, auraName, color, isPersistent)
    local auraObj = getParticleAuraTemplate(auraName)
    if not auraObj then return {} end

    local localParts = mapCharacterParts(character)
    local cloned = auraObj:Clone()
    local created = {}

    for _, part in ipairs(cloned:GetChildren()) do
        local targetPart = localParts[part.Name]
        if targetPart then
            for _, child in ipairs(part:GetChildren()) do
                local inst = child:Clone()
                inst.Name = "LarpticAuraParticle"
                inst.Parent = targetPart
                if color then
                    tintParticleSubtree(inst, color)
                end
                table.insert(created, inst)
            end
        end
    end
    cloned:Destroy()

    for _, p in ipairs(created) do
        setParticleEmittersEnabledInSubtree(p, true)
    end

    return created
end

local function refreshSelfAura()
    clearSelfAura()
    if not SelfAuraEnabled then return end
    local char = LocalPlayer.Character
    if not char then return end
    if not particleAuraIdByName[SelfAuraType] then return end
    selfAuraParticles = applyParticleAuraToCharacter(char, SelfAuraType, SelfAuraColor, true)
end

LocalPlayer.CharacterAdded:Connect(function()
    if SelfAuraEnabled then
        task.delay(0.75, refreshSelfAura)
    end
end)

local SkyboxAssets = {
    ["Black Storm"] = {
        Bk = "rbxassetid://15502511288", Dn = "rbxassetid://15502508460", Ft = "rbxassetid://15502510289",
        Lf = "rbxassetid://15502507918", Rt = "rbxassetid://15502509398", Up = "rbxassetid://15502511911",
    },
    HD = {
        Bk = "http://www.roblox.com/asset/?id=16553658937", Dn = "http://www.roblox.com/asset/?id=16553660713",
        Ft = "http://www.roblox.com/asset/?id=16553662144", Lf = "http://www.roblox.com/asset/?id=16553664042",
        Rt = "http://www.roblox.com/asset/?id=16553665766", Up = "http://www.roblox.com/asset/?id=16553667750",
    },
    Snow = {
        Bk = "http://www.roblox.com/asset/?id=155657655", Dn = "http://www.roblox.com/asset/?id=155674246",
        Ft = "http://www.roblox.com/asset/?id=155657609", Lf = "http://www.roblox.com/asset/?id=155657671",
        Rt = "http://www.roblox.com/asset/?id=155657619", Up = "http://www.roblox.com/asset/?id=155674931",
    },
    ["Blue Space"] = {
        Bk = "rbxassetid://15536110634", Dn = "rbxassetid://15536112543", Ft = "rbxassetid://15536116141",
        Lf = "rbxassetid://15536114370", Rt = "rbxassetid://15536118762", Up = "rbxassetid://15536117282",
    },
    Realistic = {
        Bk = "rbxassetid://653719502", Dn = "rbxassetid://653718790", Ft = "rbxassetid://653719067",
        Lf = "rbxassetid://653719190", Rt = "rbxassetid://653718931", Up = "rbxassetid://653719321",
    },
    Stormy = {
        Bk = "http://www.roblox.com/asset/?id=18703245834", Dn = "http://www.roblox.com/asset/?id=18703243349",
        Ft = "http://www.roblox.com/asset/?id=18703240532", Lf = "http://www.roblox.com/asset/?id=18703237556",
        Rt = "http://www.roblox.com/asset/?id=18703235430", Up = "http://www.roblox.com/asset/?id=18703232671",
    },
    Pink = {
        Bk = "rbxassetid://12216109205", Dn = "rbxassetid://12216109875", Ft = "rbxassetid://12216109489",
        Lf = "rbxassetid://12216110170", Rt = "rbxassetid://12216110471", Up = "rbxassetid://12216108877",
    },
    Sunset = {
        Bk = "rbxassetid://600830446", Dn = "rbxassetid://600831635", Ft = "rbxassetid://600832720",
        Lf = "rbxassetid://600886090", Rt = "rbxassetid://600833862", Up = "rbxassetid://600835177",
    },
    Arctic = {
        Bk = "http://www.roblox.com/asset/?id=225469390", Dn = "http://www.roblox.com/asset/?id=225469395",
        Ft = "http://www.roblox.com/asset/?id=225469403", Lf = "http://www.roblox.com/asset/?id=225469450",
        Rt = "http://www.roblox.com/asset/?id=225469471", Up = "http://www.roblox.com/asset/?id=225469481",
    },
    Space = {
        Bk = "http://www.roblox.com/asset/?id=166509999", Dn = "http://www.roblox.com/asset/?id=166510057",
        Ft = "http://www.roblox.com/asset/?id=166510116", Lf = "http://www.roblox.com/asset/?id=166510092",
        Rt = "http://www.roblox.com/asset/?id=166510131", Up = "http://www.roblox.com/asset/?id=166510114",
    },
    ["Roblox Default"] = {
        Bk = "rbxasset://textures/sky/sky512_bk.tex", Dn = "rbxasset://textures/sky/sky512_dn.tex",
        Ft = "rbxasset://textures/sky/sky512_ft.tex", Lf = "rbxasset://textures/sky/sky512_lf.tex",
        Rt = "rbxasset://textures/sky/sky512_rt.tex", Up = "rbxasset://textures/sky/sky512_up.tex",
    },
    ["Red Night"] = {
        Bk = "http://www.roblox.com/asset/?id=401664839", Dn = "http://www.roblox.com/asset/?id=401664862",
        Ft = "http://www.roblox.com/asset/?id=401664960", Lf = "http://www.roblox.com/asset/?id=401664881",
        Rt = "http://www.roblox.com/asset/?id=401664901", Up = "http://www.roblox.com/asset/?id=401664936",
    },
    ["Deep Space 1"] = {
        Bk = "http://www.roblox.com/asset/?id=149397692", Dn = "http://www.roblox.com/asset/?id=149397686",
        Ft = "http://www.roblox.com/asset/?id=149397697", Lf = "http://www.roblox.com/asset/?id=149397684",
        Rt = "http://www.roblox.com/asset/?id=149397688", Up = "http://www.roblox.com/asset/?id=149397702",
    },
    ["Pink Skies"] = {
        Bk = "http://www.roblox.com/asset/?id=151165214", Dn = "http://www.roblox.com/asset/?id=151165197",
        Ft = "http://www.roblox.com/asset/?id=151165224", Lf = "http://www.roblox.com/asset/?id=151165191",
        Rt = "http://www.roblox.com/asset/?id=151165206", Up = "http://www.roblox.com/asset/?id=151165227",
    },
    ["Purple Sunset"] = {
        Bk = "rbxassetid://264908339", Dn = "rbxassetid://264907909", Ft = "rbxassetid://264909420",
        Lf = "rbxassetid://264909758", Rt = "rbxassetid://264908886", Up = "rbxassetid://264907379",
    },
    ["Blue Night"] = {
        Bk = "http://www.roblox.com/asset/?id=12064107", Dn = "http://www.roblox.com/asset/?id=12064152",
        Ft = "http://www.roblox.com/asset/?id=12064121", Lf = "http://www.roblox.com/asset/?id=12063984",
        Rt = "http://www.roblox.com/asset/?id=12064115", Up = "http://www.roblox.com/asset/?id=12064131",
    },
    ["Blossom Daylight"] = {
        Bk = "http://www.roblox.com/asset/?id=271042516", Dn = "http://www.roblox.com/asset/?id=271077243",
        Ft = "http://www.roblox.com/asset/?id=271042556", Lf = "http://www.roblox.com/asset/?id=271042310",
        Rt = "http://www.roblox.com/asset/?id=271042467", Up = "http://www.roblox.com/asset/?id=271077958",
    },
    ["Blue Nebula"] = {
        Bk = "http://www.roblox.com/asset?id=135207744", Dn = "http://www.roblox.com/asset?id=135207662",
        Ft = "http://www.roblox.com/asset?id=135207770", Lf = "http://www.roblox.com/asset?id=135207615",
        Rt = "http://www.roblox.com/asset?id=135207695", Up = "http://www.roblox.com/asset?id=135207794",
    },
    ["Blue Planet"] = {
        Bk = "rbxassetid://218955819", Dn = "rbxassetid://218953419", Ft = "rbxassetid://218954524",
        Lf = "rbxassetid://218958493", Rt = "rbxassetid://218957134", Up = "rbxassetid://218950090",
    },
    ["Deep Space 2"] = {
        Bk = "http://www.roblox.com/asset/?id=159248188", Dn = "http://www.roblox.com/asset/?id=159248183",
        Ft = "http://www.roblox.com/asset/?id=159248187", Lf = "http://www.roblox.com/asset/?id=159248173",
        Rt = "http://www.roblox.com/asset/?id=159248192", Up = "http://www.roblox.com/asset/?id=159248176",
    },
    Summer = {
        Bk = "rbxassetid://16648590964", Dn = "rbxassetid://16648617436", Ft = "rbxassetid://16648595424",
        Lf = "rbxassetid://16648566370", Rt = "rbxassetid://16648577071", Up = "rbxassetid://16648598180",
    },
    Galaxy = {
        Bk = "rbxassetid://15983968922", Dn = "rbxassetid://15983966825", Ft = "rbxassetid://15983965025",
        Lf = "rbxassetid://15983967420", Rt = "rbxassetid://15983966246", Up = "rbxassetid://15983964246",
    },
    Stylized = {
        Bk = "rbxassetid://18351376859", Dn = "rbxassetid://18351374919", Ft = "rbxassetid://18351376800",
        Lf = "rbxassetid://18351376469", Rt = "rbxassetid://18351376457", Up = "rbxassetid://18351377189",
    },
    Minecraft = {
        Bk = "rbxassetid://8735166756", Dn = "http://www.roblox.com/asset/?id=8735166707",
        Ft = "http://www.roblox.com/asset/?id=8735231668", Lf = "http://www.roblox.com/asset/?id=8735166755",
        Rt = "http://www.roblox.com/asset/?id=8735166751", Up = "http://www.roblox.com/asset/?id=8735166729",
    },
    ["Cloudy Rain"] = {
        Bk = "http://www.roblox.com/asset/?id=4498828382", Dn = "http://www.roblox.com/asset/?id=4498828812",
        Ft = "http://www.roblox.com/asset/?id=4498829917", Lf = "http://www.roblox.com/asset/?id=4498830911",
        Rt = "http://www.roblox.com/asset/?id=4498830417", Up = "http://www.roblox.com/asset/?id=4498831746",
    },
    ["Black Cloudy Rain"] = {
        Bk = "http://www.roblox.com/asset/?id=149679669", Dn = "http://www.roblox.com/asset/?id=149681979",
        Ft = "http://www.roblox.com/asset/?id=149679690", Lf = "http://www.roblox.com/asset/?id=149679709",
        Rt = "http://www.roblox.com/asset/?id=149679722", Up = "http://www.roblox.com/asset/?id=149680199",
    },
}

local DefaultSky = Lighting:FindFirstChildOfClass("Sky")
local DefaultSkySettings = {}
if DefaultSky then
    DefaultSkySettings.SkyboxBk = DefaultSky.SkyboxBk
    DefaultSkySettings.SkyboxDn = DefaultSky.SkyboxDn
    DefaultSkySettings.SkyboxFt = DefaultSky.SkyboxFt
    DefaultSkySettings.SkyboxLf = DefaultSky.SkyboxLf
    DefaultSkySettings.SkyboxRt = DefaultSky.SkyboxRt
    DefaultSkySettings.SkyboxUp = DefaultSky.SkyboxUp
end

local SkyboxEnabled = false
local CurrentSkybox = "HD"
local skyboxList = {}
for name in pairs(SkyboxAssets) do
    table.insert(skyboxList, name)
end
table.sort(skyboxList)

local function Skybox_Apply(name)
    local data = SkyboxAssets[name]
    if not data then return end
    local sky = Lighting:FindFirstChildOfClass("Sky")
    if not sky then
        sky = Instance.new("Sky")
        sky.Parent = Lighting
    end
    sky.SkyboxBk = data.Bk
    sky.SkyboxDn = data.Dn
    sky.SkyboxFt = data.Ft
    sky.SkyboxLf = data.Lf
    sky.SkyboxRt = data.Rt
    sky.SkyboxUp = data.Up
end

local function Skybox_RestoreDefault()
    local sky = Lighting:FindFirstChildOfClass("Sky")
    if sky and DefaultSkySettings.SkyboxBk then
        sky.SkyboxBk = DefaultSkySettings.SkyboxBk
        sky.SkyboxDn = DefaultSkySettings.SkyboxDn
        sky.SkyboxFt = DefaultSkySettings.SkyboxFt
        sky.SkyboxLf = DefaultSkySettings.SkyboxLf
        sky.SkyboxRt = DefaultSkySettings.SkyboxRt
        sky.SkyboxUp = DefaultSkySettings.SkyboxUp
    elseif sky then
        sky:Destroy()
    end
end

local defaultLighting = {
    ClockTime = Lighting.ClockTime,
    Brightness = Lighting.Brightness,
    Ambient = Lighting.Ambient,
    OutdoorAmbient = Lighting.OutdoorAmbient,
    ColorShift_Top = Lighting.ColorShift_Top,
    ColorShift_Bottom = Lighting.ColorShift_Bottom,
    EnvironmentDiffuseScale = Lighting.EnvironmentDiffuseScale,
    EnvironmentSpecularScale = Lighting.EnvironmentSpecularScale,
    GlobalShadows = Lighting.GlobalShadows,
    ExposureCompensation = Lighting.ExposureCompensation,
    FogStart = Lighting.FogStart,
    FogEnd = Lighting.FogEnd,
    FogColor = Lighting.FogColor,
    GeographicLatitude = Lighting.GeographicLatitude,
}

local function getOrCreate(className, name)
    local obj = Lighting:FindFirstChild(name)
    if obj and obj:IsA(className) then return obj end
    obj = Instance.new(className)
    obj.Name = name
    obj.Parent = Lighting
    return obj
end

local function applyShaderPreset(preset)
    Lighting.ClockTime = preset.ClockTime or 12
    Lighting.Brightness = preset.Brightness or 2
    Lighting.Ambient = preset.Ambient or Color3.fromRGB(100, 100, 100)
    Lighting.OutdoorAmbient = preset.OutdoorAmbient or Color3.fromRGB(128, 128, 128)
    Lighting.ColorShift_Top = preset.ColorShift_Top or Color3.new(0, 0, 0)
    Lighting.ColorShift_Bottom = preset.ColorShift_Bottom or Color3.new(0, 0, 0)
    Lighting.EnvironmentDiffuseScale = preset.EnvironmentDiffuseScale or 1
    Lighting.EnvironmentSpecularScale = preset.EnvironmentSpecularScale or 1
    Lighting.GlobalShadows = preset.GlobalShadows ~= false
    Lighting.ExposureCompensation = preset.ExposureCompensation or 0
    Lighting.FogStart = preset.FogStart or 0
    Lighting.FogEnd = preset.FogEnd or 100000
    Lighting.FogColor = preset.FogColor or Color3.fromRGB(192, 192, 192)
    Lighting.GeographicLatitude = preset.GeographicLatitude or 41.7

    local cc = getOrCreate("ColorCorrectionEffect", "HubCC")
    cc.Enabled = true
    cc.Brightness = preset.CC_Brightness or 0
    cc.Contrast = preset.CC_Contrast or 0
    cc.Saturation = preset.CC_Saturation or 0
    cc.TintColor = preset.CC_Tint or Color3.new(1, 1, 1)

    local bloom = getOrCreate("BloomEffect", "HubBloom")
    bloom.Enabled = true
    bloom.Intensity = preset.BloomIntensity or 0.4
    bloom.Size = preset.BloomSize or 24
    bloom.Threshold = preset.BloomThreshold or 0.95

    local blur = getOrCreate("BlurEffect", "HubBlur")
    blur.Enabled = preset.BlurSize and preset.BlurSize > 0
    blur.Size = preset.BlurSize or 0

    local atm = getOrCreate("Atmosphere", "HubAtm")
    atm.Density = preset.AtmDensity or 0.3
    atm.Offset = preset.AtmOffset or 0
    atm.Color = preset.AtmColor or Color3.fromRGB(199, 212, 255)
    atm.Decay = preset.AtmDecay or Color3.fromRGB(106, 112, 125)
    atm.Glare = preset.AtmGlare or 0
    atm.Haze = preset.AtmHaze or 0

    local sun = getOrCreate("SunRaysEffect", "HubSunRays")
    sun.Enabled = preset.SunRays ~= false
    sun.Intensity = preset.SunIntensity or 0.1
    sun.Spread = preset.SunSpread or 0.5
end

local function resetShader()
    Lighting.ClockTime = defaultLighting.ClockTime
    Lighting.Brightness = defaultLighting.Brightness
    Lighting.Ambient = defaultLighting.Ambient
    Lighting.OutdoorAmbient = defaultLighting.OutdoorAmbient
    Lighting.ColorShift_Top = defaultLighting.ColorShift_Top
    Lighting.ColorShift_Bottom = defaultLighting.ColorShift_Bottom
    Lighting.EnvironmentDiffuseScale = defaultLighting.EnvironmentDiffuseScale
    Lighting.EnvironmentSpecularScale = defaultLighting.EnvironmentSpecularScale
    Lighting.GlobalShadows = defaultLighting.GlobalShadows
    Lighting.ExposureCompensation = defaultLighting.ExposureCompensation
    Lighting.FogStart = defaultLighting.FogStart
    Lighting.FogEnd = defaultLighting.FogEnd
    Lighting.FogColor = defaultLighting.FogColor
    Lighting.GeographicLatitude = defaultLighting.GeographicLatitude

    for _, name in ipairs({"HubCC", "HubBloom", "HubBlur", "HubAtm", "HubSunRays"}) do
        local obj = Lighting:FindFirstChild(name)
        if obj then obj:Destroy() end
    end
end

local ShaderPresets = {
    Morning = {
        ClockTime = 7.5, Brightness = 2.2, Ambient = Color3.fromRGB(160, 140, 120),
        OutdoorAmbient = Color3.fromRGB(180, 160, 140), ColorShift_Top = Color3.fromRGB(255, 200, 150),
        ExposureCompensation = 0.1, FogStart = 50, FogEnd = 2000, FogColor = Color3.fromRGB(255, 220, 180),
        CC_Brightness = 0.05, CC_Contrast = 0.05, CC_Saturation = 0.1, CC_Tint = Color3.fromRGB(255, 245, 230),
        BloomIntensity = 0.5, BloomSize = 28, BloomThreshold = 0.9,
        AtmDensity = 0.25, AtmColor = Color3.fromRGB(255, 220, 180), AtmDecay = Color3.fromRGB(200, 160, 120),
        AtmGlare = 0.3, AtmHaze = 1, SunRays = true, SunIntensity = 0.15,
    },
    Midday = {
        ClockTime = 12, Brightness = 3, Ambient = Color3.fromRGB(140, 140, 150),
        OutdoorAmbient = Color3.fromRGB(180, 180, 190), ColorShift_Top = Color3.fromRGB(255, 255, 240),
        ExposureCompensation = 0, FogStart = 0, FogEnd = 100000, FogColor = Color3.fromRGB(192, 192, 192),
        CC_Brightness = 0, CC_Contrast = 0.1, CC_Saturation = 0.05, CC_Tint = Color3.new(1, 1, 1),
        BloomIntensity = 0.6, BloomSize = 24, BloomThreshold = 0.95,
        AtmDensity = 0.2, AtmColor = Color3.fromRGB(200, 220, 255), AtmDecay = Color3.fromRGB(120, 140, 180),
        AtmGlare = 0.5, AtmHaze = 0.5, SunRays = true, SunIntensity = 0.25,
    },
    Afternoon = {
        ClockTime = 16, Brightness = 2.5, Ambient = Color3.fromRGB(150, 130, 110),
        OutdoorAmbient = Color3.fromRGB(170, 150, 130), ColorShift_Top = Color3.fromRGB(255, 180, 120),
        ExposureCompensation = 0.05, FogStart = 80, FogEnd = 2500, FogColor = Color3.fromRGB(255, 200, 150),
        CC_Brightness = 0.02, CC_Contrast = 0.08, CC_Saturation = 0.12, CC_Tint = Color3.fromRGB(255, 240, 220),
        BloomIntensity = 0.55, BloomSize = 26, BloomThreshold = 0.92,
        AtmDensity = 0.28, AtmColor = Color3.fromRGB(255, 200, 150), AtmDecay = Color3.fromRGB(180, 140, 100),
        AtmGlare = 0.4, AtmHaze = 1.2, SunRays = true, SunIntensity = 0.2,
    },
    Evening = {
        ClockTime = 18.5, Brightness = 1.5, Ambient = Color3.fromRGB(100, 70, 60),
        OutdoorAmbient = Color3.fromRGB(120, 80, 70), ColorShift_Top = Color3.fromRGB(255, 120, 60),
        ExposureCompensation = -0.1, FogStart = 30, FogEnd = 1500, FogColor = Color3.fromRGB(200, 100, 60),
        CC_Brightness = -0.05, CC_Contrast = 0.15, CC_Saturation = 0.2, CC_Tint = Color3.fromRGB(255, 200, 170),
        BloomIntensity = 0.7, BloomSize = 32, BloomThreshold = 0.85,
        AtmDensity = 0.4, AtmColor = Color3.fromRGB(255, 150, 80), AtmDecay = Color3.fromRGB(150, 80, 50),
        AtmGlare = 0.8, AtmHaze = 2, SunRays = true, SunIntensity = 0.3,
    },
    Night = {
        ClockTime = 21, Brightness = 0.8, Ambient = Color3.fromRGB(40, 50, 80),
        OutdoorAmbient = Color3.fromRGB(30, 40, 70), ColorShift_Top = Color3.fromRGB(60, 80, 150),
        ExposureCompensation = -0.3, FogStart = 20, FogEnd = 800, FogColor = Color3.fromRGB(30, 40, 70),
        CC_Brightness = -0.1, CC_Contrast = 0.1, CC_Saturation = -0.1, CC_Tint = Color3.fromRGB(180, 200, 255),
        BloomIntensity = 0.3, BloomSize = 20, BloomThreshold = 1,
        AtmDensity = 0.35, AtmColor = Color3.fromRGB(40, 60, 120), AtmDecay = Color3.fromRGB(20, 30, 60),
        AtmGlare = 0.1, AtmHaze = 1.5, SunRays = false,
    },
    Midnight = {
        ClockTime = 0, Brightness = 0.4, Ambient = Color3.fromRGB(20, 25, 40),
        OutdoorAmbient = Color3.fromRGB(15, 20, 35), ColorShift_Top = Color3.fromRGB(30, 40, 80),
        ExposureCompensation = -0.5, FogStart = 10, FogEnd = 500, FogColor = Color3.fromRGB(15, 20, 40),
        CC_Brightness = -0.15, CC_Contrast = 0.05, CC_Saturation = -0.2, CC_Tint = Color3.fromRGB(150, 170, 220),
        BloomIntensity = 0.2, BloomSize = 16, BloomThreshold = 1.1,
        AtmDensity = 0.45, AtmColor = Color3.fromRGB(20, 30, 60), AtmDecay = Color3.fromRGB(10, 15, 30),
        AtmGlare = 0, AtmHaze = 2, SunRays = false,
    },
    Rain = {
        ClockTime = 14, Brightness = 1.2, Ambient = Color3.fromRGB(90, 100, 110),
        OutdoorAmbient = Color3.fromRGB(80, 90, 100), ExposureCompensation = -0.2,
        FogStart = 10, FogEnd = 400, FogColor = Color3.fromRGB(100, 110, 120),
        CC_Brightness = -0.05, CC_Contrast = 0.05, CC_Saturation = -0.15, CC_Tint = Color3.fromRGB(200, 210, 220),
        BloomIntensity = 0.25, AtmDensity = 0.55, AtmColor = Color3.fromRGB(120, 130, 140),
        AtmDecay = Color3.fromRGB(80, 90, 100), AtmHaze = 3, BlurSize = 2, SunRays = false,
    },
    Snow = {
        ClockTime = 12, Brightness = 2.5, Ambient = Color3.fromRGB(200, 210, 220),
        OutdoorAmbient = Color3.fromRGB(220, 230, 240), ExposureCompensation = 0.2,
        FogStart = 30, FogEnd = 600, FogColor = Color3.fromRGB(220, 230, 240),
        CC_Brightness = 0.1, CC_Contrast = 0.05, CC_Saturation = -0.05, CC_Tint = Color3.fromRGB(240, 245, 255),
        BloomIntensity = 0.4, AtmDensity = 0.4, AtmColor = Color3.fromRGB(230, 240, 255),
        AtmDecay = Color3.fromRGB(180, 190, 210), AtmHaze = 2, SunRays = true, SunIntensity = 0.1,
    },
    Fog = {
        ClockTime = 10, Brightness = 1, Ambient = Color3.fromRGB(120, 120, 130),
        OutdoorAmbient = Color3.fromRGB(110, 110, 120), ExposureCompensation = -0.15,
        FogStart = 5, FogEnd = 150, FogColor = Color3.fromRGB(160, 165, 170),
        CC_Brightness = 0, CC_Contrast = -0.05, CC_Saturation = -0.2, CC_Tint = Color3.fromRGB(210, 215, 220),
        BloomIntensity = 0.2, AtmDensity = 0.7, AtmColor = Color3.fromRGB(180, 185, 190),
        AtmDecay = Color3.fromRGB(140, 145, 150), AtmHaze = 5, BlurSize = 3, SunRays = false,
    },
    Storm = {
        ClockTime = 15, Brightness = 0.7, Ambient = Color3.fromRGB(50, 55, 70),
        OutdoorAmbient = Color3.fromRGB(40, 45, 60), ExposureCompensation = -0.4,
        FogStart = 5, FogEnd = 300, FogColor = Color3.fromRGB(40, 45, 55),
        CC_Brightness = -0.1, CC_Contrast = 0.2, CC_Saturation = -0.25, CC_Tint = Color3.fromRGB(160, 170, 200),
        BloomIntensity = 0.15, AtmDensity = 0.6, AtmColor = Color3.fromRGB(50, 60, 80),
        AtmDecay = Color3.fromRGB(30, 35, 50), AtmHaze = 4, BlurSize = 2, SunRays = false,
    },
    Sunny = {
        ClockTime = 13, Brightness = 3.5, Ambient = Color3.fromRGB(160, 160, 150),
        OutdoorAmbient = Color3.fromRGB(200, 200, 190), ColorShift_Top = Color3.fromRGB(255, 255, 220),
        ExposureCompensation = 0.15, FogStart = 0, FogEnd = 100000,
        CC_Brightness = 0.05, CC_Contrast = 0.15, CC_Saturation = 0.15, CC_Tint = Color3.fromRGB(255, 255, 240),
        BloomIntensity = 0.8, BloomSize = 30, BloomThreshold = 0.9,
        AtmDensity = 0.15, AtmColor = Color3.fromRGB(220, 230, 255), AtmGlare = 1, AtmHaze = 0.3,
        SunRays = true, SunIntensity = 0.35,
    },
    Red = {
        ClockTime = 12, Brightness = 2, Ambient = Color3.fromRGB(80, 30, 30),
        OutdoorAmbient = Color3.fromRGB(100, 40, 40), CC_Tint = Color3.fromRGB(255, 120, 120),
        CC_Saturation = 0.3, CC_Contrast = 0.1, BloomIntensity = 0.5,
        AtmColor = Color3.fromRGB(200, 50, 50), AtmDecay = Color3.fromRGB(100, 20, 20), AtmDensity = 0.35,
    },
    Blue = {
        ClockTime = 12, Brightness = 2, Ambient = Color3.fromRGB(30, 40, 80),
        OutdoorAmbient = Color3.fromRGB(40, 50, 100), CC_Tint = Color3.fromRGB(150, 180, 255),
        CC_Saturation = 0.2, BloomIntensity = 0.5,
        AtmColor = Color3.fromRGB(80, 120, 220), AtmDecay = Color3.fromRGB(30, 50, 120), AtmDensity = 0.35,
    },
    Green = {
        ClockTime = 12, Brightness = 2, Ambient = Color3.fromRGB(30, 70, 40),
        OutdoorAmbient = Color3.fromRGB(40, 90, 50), CC_Tint = Color3.fromRGB(150, 255, 170),
        CC_Saturation = 0.25, BloomIntensity = 0.5,
        AtmColor = Color3.fromRGB(80, 200, 100), AtmDecay = Color3.fromRGB(30, 100, 50), AtmDensity = 0.35,
    },
    Purple = {
        ClockTime = 12, Brightness = 2, Ambient = Color3.fromRGB(50, 30, 80),
        OutdoorAmbient = Color3.fromRGB(70, 40, 100), CC_Tint = Color3.fromRGB(200, 150, 255),
        CC_Saturation = 0.25, BloomIntensity = 0.5,
        AtmColor = Color3.fromRGB(150, 80, 220), AtmDecay = Color3.fromRGB(70, 30, 120), AtmDensity = 0.35,
    },
    Pink = {
        ClockTime = 12, Brightness = 2, Ambient = Color3.fromRGB(80, 40, 60),
        OutdoorAmbient = Color3.fromRGB(100, 50, 80), CC_Tint = Color3.fromRGB(255, 180, 220),
        CC_Saturation = 0.3, BloomIntensity = 0.5,
        AtmColor = Color3.fromRGB(255, 150, 200), AtmDecay = Color3.fromRGB(150, 70, 110), AtmDensity = 0.35,
    },
}

local AutoThrowEnabled = false
local AutoKillAllEnabled = false
local autoThrowReady = true
local autoKillReady = true
local killingPlayer = nil

local function murderGetPlayers()
    return Players:GetPlayers()
end

local function throwKnife()
    task.spawn(function()
        if getRole(LocalPlayer) ~= "Murderer" then
            return
        end
        if isDead(LocalPlayer) then
            return
        end
        local Character = LocalPlayer.Character
        local hrp = Character and Character:FindFirstChild("HumanoidRootPart")
        if not hrp then
            return
        end

        local nearest = nil
        local nearestDist = math.huge
        for _, plr in ipairs(murderGetPlayers()) do
            if plr ~= LocalPlayer and not isDead(plr) and getRole(plr) ~= "Unknown" then
                local otherChar = plr.Character
                local otherHRP = otherChar and otherChar:FindFirstChild("HumanoidRootPart")
                if otherHRP then
                    local dist = (hrp.Position - otherHRP.Position).Magnitude
                    if dist < nearestDist then
                        nearestDist = dist
                        nearest = plr
                    end
                end
            end
        end
        if not nearest or not nearest.Character then
            return
        end
        local targetHRP = nearest.Character:FindFirstChild("HumanoidRootPart")
        if not targetHRP then
            return
        end

        local Knife = Character:FindFirstChild("Knife") or LocalPlayer.Backpack:FindFirstChild("Knife")
        if not Knife then
            return
        end
        if Character ~= Knife.Parent then
            Knife.Parent = Character
            task.wait(0.1)
        end
        local Knife2 = Character:FindFirstChild("Knife")
        if not Knife2 then
            return
        end
        local Handle = Knife2:FindFirstChild("Handle")
        local Events = Knife2:FindFirstChild("Events")
        local KnifeThrown = Events and Events:FindFirstChild("KnifeThrown")
        if not KnifeThrown or not Handle then
            return
        end
        KnifeThrown:FireServer(Handle.CFrame, CFrame.new(targetHRP.Position, hrp.Position))
    end)
end

local function killPlayer(target)
    task.spawn(function()
        local Character = LocalPlayer.Character
        if not Character then
            return
        end
        local targetChar = target.Character
        local targetHRP = targetChar and targetChar:FindFirstChild("HumanoidRootPart")
        if not targetHRP then
            return
        end

        killingPlayer = target.Name

        local Knife = Character:FindFirstChild("Knife") or LocalPlayer.Backpack:FindFirstChild("Knife")
        if Knife and Character ~= Knife.Parent then
            Knife.Parent = Character
        end
        local Knife3 = Character:FindFirstChild("Knife")
        if not Knife3 then
            killingPlayer = nil
            return
        end

        local Handle = Knife3:FindFirstChild("Handle")
        local Events = Knife3:FindFirstChild("Events")
        local HandleTouched = Events and Events:FindFirstChild("HandleTouched")

        if Handle and HandleTouched then
            local Weld = Handle:FindFirstChildWhichIsA("Weld") or Handle:FindFirstChildWhichIsA("WeldConstraint")
            if Weld then
                Weld.Enabled = false
            end

            local HandleParent = Handle.Parent
            local HandleCFrame = Handle.CFrame

            Handle.Parent = workspace
            Handle.CFrame = targetHRP.CFrame
            task.wait()
            HandleTouched:FireServer(targetHRP)
            task.wait()
            Handle.CFrame = HandleCFrame
            Handle.Parent = HandleParent

            if Weld then
                Weld.Enabled = true
            end
        end

        killingPlayer = nil
    end)
end

local function killAll()
    task.spawn(function()
        local Character = LocalPlayer.Character
        if not Character then
            return
        end
        if getRole(LocalPlayer) ~= "Murderer" then
            return
        end
        if isDead(LocalPlayer) then
            return
        end

        local Knife = Character:FindFirstChild("Knife") or LocalPlayer.Backpack:FindFirstChild("Knife")
        if Knife and Character ~= Knife.Parent then
            Knife.Parent = Character
            task.wait(0.1)
        end
        local Knife4 = Character:FindFirstChild("Knife")
        if not Knife4 then
            return
        end
        local Handle = Knife4:FindFirstChild("Handle")
        local Events = Knife4:FindFirstChild("Events")
        local HandleTouched = Events and Events:FindFirstChild("HandleTouched")
        if not Handle or not HandleTouched then
            return
        end

        local targets = {}
        for _, plr in ipairs(murderGetPlayers()) do
            if plr ~= LocalPlayer and not isDead(plr) and getRole(plr) ~= "Unknown" then
                local otherChar = plr.Character
                local otherHRP = otherChar and otherChar:FindFirstChild("HumanoidRootPart")
                if otherHRP then
                    table.insert(targets, otherHRP)
                end
            end
        end
        if #targets == 0 then
            return
        end

        local Weld = Handle:FindFirstChildWhichIsA("Weld") or Handle:FindFirstChildWhichIsA("WeldConstraint")
        if Weld then
            Weld.Enabled = false
        end
        local HandleParent = Handle.Parent
        local HandleCFrame = Handle.CFrame
        Handle.Parent = workspace
        for _, hrpPart in ipairs(targets) do
            pcall(function()
                Handle.CFrame = hrpPart.CFrame
                task.wait()
                HandleTouched:FireServer(hrpPart)
                task.wait()
            end)
        end
        Handle.CFrame = HandleCFrame
        Handle.Parent = HandleParent
        if Weld then
            Weld.Enabled = true
        end
    end)
end

local function killSheriff()
    for _, plr in ipairs(murderGetPlayers()) do
        if plr ~= LocalPlayer and not isDead(plr) then
            local role = getRole(plr)
            if role == "Sheriff" or role == "Hero" then
                task.spawn(function()
                    killPlayer(plr)
                end)
                return
            end
        end
    end
end

RunService.Heartbeat:Connect(function()
    if AutoThrowEnabled and autoThrowReady then
        autoThrowReady = false
        throwKnife()
        task.delay(0.25, function()
            autoThrowReady = true
        end)
    end
end)

RunService.Heartbeat:Connect(function()
    if AutoKillAllEnabled and autoKillReady then
        autoKillReady = false
        killAll()
        task.delay(0.1, function()
            autoKillReady = true
        end)
    end
end)

local ChinaHatEnabled = false
local ChinaHatColor = Color3.fromRGB(255, 105, 180)
local ChinaHatScale = Vector3.new(1.7, 1.1, 1.7)
local chinaHatPart = nil

local function destroyChinaHat()
    if chinaHatPart then
        pcall(function() chinaHatPart:Destroy() end)
        chinaHatPart = nil
    end
    local char = LocalPlayer.Character
    if char then
        for _, child in ipairs(char:GetChildren()) do
            if child.Name == "HubChinaHat" then
                pcall(function() child:Destroy() end)
            end
        end
    end
end

local function createChinaHat(character)
    destroyChinaHat()
    if not ChinaHatEnabled or not character then return end
    local Head = character:FindFirstChild("Head")
    if not Head then return end

    local Cone = Instance.new("Part")
    Cone.Name = "HubChinaHat"
    Cone.Size = Vector3.new(1, 1, 1)
    Cone.Material = Enum.Material.Neon
    Cone.Transparency = 0.2
    Cone.Anchored = false
    Cone.CanCollide = false
    Cone.Massless = true
    Cone.Color = ChinaHatColor

    local Mesh = Instance.new("SpecialMesh")
    Mesh.MeshType = Enum.MeshType.FileMesh
    Mesh.MeshId = "rbxassetid://1033714"
    Mesh.Scale = ChinaHatScale
    Mesh.Parent = Cone

    local Weld = Instance.new("Weld")
    Weld.Part0 = Head
    Weld.Part1 = Cone
    Weld.C0 = CFrame.new(0, 0.9, 0)
    Weld.Parent = Cone

    local Light = Instance.new("PointLight")
    Light.Color = ChinaHatColor
    Light.Brightness = 0
    Light.Range = 12
    Light.Shadows = true
    Light.Parent = Cone

    Cone.Parent = character
    chinaHatPart = Cone
end

LocalPlayer.CharacterAdded:Connect(function(character)
    task.wait(0.5)
    if ChinaHatEnabled then
        createChinaHat(character)
    end
end)

if LocalPlayer.Character and ChinaHatEnabled then
    createChinaHat(LocalPlayer.Character)
end

local MainTab = Window:Tab({ Title = "Player" })
local CombatTab = Window:Tab({ Title = "Combat" })
local EspTab = Window:Tab({ Title = "ESP" })
local VisualTab = Window:Tab({ Title = "Visuals" })
local ShaderTab = Window:Tab({ Title = "Shaders" })
local AutofarmTab = Window:Tab({ Title = "Autofarm" })

local PlayerMove = MainTab:Section("Movement", "Left")
local PlayerChar = MainTab:Section("Character", "Right")
local PlayerTP = MainTab:Section("Teleport", "Left")
local CombatSheriff = CombatTab:Section("Sheriff", "Left")
local CombatMurder = CombatTab:Section("Murder", "Right")
local CombatFling = CombatTab:Section("Fling", "Left")
local CombatSounds = CombatTab:Section("Kill Sounds", "Right")
local CombatGunMorph = CombatTab:Section("Gun Morph", "Left")
local EspMain = EspTab:Section("ESP", "Left")
local EspColors = EspTab:Section("Colors", "Right")
local VisualAura = VisualTab:Section("Aura", "Left")
local VisualChar = VisualTab:Section("Visual Objects", "Right")
local VisualChams = VisualTab:Section("Chams", "Left")
local VisualBeam = VisualTab:Section("Gun Beam", "Right")
local VisualTrack = VisualTab:Section("Backtrack", "Left")
local ShaderMain = ShaderTab:Section("Shaders", "Left")
local ShaderSky = ShaderTab:Section("Sky", "Right")
local FarmMain = AutofarmTab:Section("Autofarm", "Left")
local FarmStatus = AutofarmTab:Section("Status", "Right")

statusLabelRef = FarmStatus:Paragraph({
    Title = "Current Status",
    Desc = PlayerStatus,
})

FarmStatus:Button({
    Title = "Refresh Status",
    Callback = function()
        local s = refreshPlayerStatus()
        notify("Status", s)
        pcall(function()
            if statusLabelRef and statusLabelRef.SetDesc then
                statusLabelRef:SetDesc(s)
            end
        end)
    end,
})

FarmStatus:Toggle({
    Title = "Round Timer",
    Value = false,
    Callback = function(v)
        pcall(function()
            if getgenv().PH_SetRoundTimer then getgenv().PH_SetRoundTimer(v) end
        end)
        notify("Status", v and "Round Timer ON" or "Round Timer OFF")
    end,
})

task.spawn(function()
    while true do
        refreshPlayerStatus()
        task.wait(1)
    end
end)

PlayerMove:Button({
    Title = "Big Boom",
    Callback = function()
        task.spawn(function()
            pcall(function()
                if getgenv().PH_BigBoomInnocent then
                    getgenv().PH_BigBoomInnocent()
                end
            end)
        end)
    end,
})

PlayerMove:Slider({
    Title = "WalkSpeed",
    Step = 1,
    Value = { Min = 16, Max = 100, Default = 16 },
    Callback = function(v)
        WalkSpeedValue = v
        if humanoid then humanoid.WalkSpeed = v end
    end,
})

PlayerMove:Slider({
    Title = "JumpPower",
    Step = 1,
    Value = { Min = 50, Max = 200, Default = 50 },
    Callback = function(v)
        JumpPowerValue = v
        if humanoid then
            humanoid.JumpPower = v
            humanoid.UseJumpPower = true
        end
    end,
})

PlayerMove:Toggle({
    Title = "Infinite Jump",
    Value = false,
    Callback = function(v) InfJump = v end,
})

PlayerMove:Toggle({
    Title = "Speed Glitch",
    Value = false,
    Callback = function(v) SpeedGlitch = v end,
})

PlayerMove:Slider({
    Title = "Speed Glitch Value",
    Step = 1,
    Value = { Min = 20, Max = 120, Default = 50 },
    Callback = function(v) SpeedGlitchValue = v end,
})

PlayerMove:Toggle({
    Title = "Noclip",
    Value = false,
    Callback = function(v)
        setNoclip(v)
        notify("Player", v and "Noclip ON" or "Noclip OFF")
    end,
})

PlayerMove:Toggle({
    Title = "Bhop",
    Value = false,
    Callback = function(v)
        boost_on = v
        notify("Player", v and "Bhop ON" or "Bhop OFF")
    end,
})

PlayerMove:Slider({
    Title = "Bhop Power",
    Step = 1,
    Value = { Min = 10, Max = 150, Default = 40 },
    Callback = function(v)
        boost_value = v
    end,
})

PlayerMove:Toggle({
    Title = "Bhop Strafe",
    Value = false,
    Callback = function(v)
        boost_strafe_on = v
    end,
})

PlayerMove:Toggle({
    Title = "Bhop Auto Strafe",
    Value = false,
    Callback = function(v)
        boost_auto_strafe_on = v
    end,
})

PlayerMove:Toggle({
    Title = "Wallhop",
    Value = false,
    Callback = function(v)
        pcall(function()
            if getgenv().PH_SetWallhop then
                getgenv().PH_SetWallhop(v)
            end
        end)
        notify("Player", v and "Wallhop ON" or "Wallhop OFF")
    end,
})

PlayerMove:Toggle({
    Title = "Anti AFK",
    Value = false,
    Callback = function(v)
        pcall(function()
            if getgenv().PH_SetAntiAFK then getgenv().PH_SetAntiAFK(v) end
        end)
        notify("Player", v and "Anti AFK ON" or "Anti AFK OFF")
    end,
})

PlayerChar:Toggle({
    Title = "Korblox",
    Value = false,
    Callback = function(v)
        pcall(function()
            if getgenv().PH_SetKorblox then
                getgenv().PH_SetKorblox(v)
            end
        end)
        notify("Player", v and "Korblox ON" or "Korblox OFF")
    end,
})

PlayerChar:Toggle({
    Title = "Headless",
    Value = false,
    Callback = function(v)
        pcall(function()
            if getgenv().PH_SetHeadless then
                getgenv().PH_SetHeadless(v)
            end
        end)
        notify("Player", v and "Headless ON" or "Headless OFF")
    end,
})

PlayerChar:Textbox({
    Title = "Model Asset ID",
    Default = "",
    Placeholder = "rbxassetid or number",
    Callback = function(text)
        pcall(function()
            if getgenv().PH_SetCustomModelId then
                getgenv().PH_SetCustomModelId(text)
            end
        end)
    end,
})

PlayerChar:Button({
    Title = "Apply Custom Model",
    Callback = function()
        pcall(function()
            if getgenv().PH_ApplyCustomModel then
                getgenv().PH_ApplyCustomModel()
            end
        end)
    end,
})

PlayerChar:Button({
    Title = "Clear Custom Model",
    Callback = function()
        pcall(function()
            if getgenv().PH_ClearCustomModel then
                getgenv().PH_ClearCustomModel()
            end
        end)
        notify("Player", "Custom model cleared")
    end,
})

PlayerChar:Toggle({
    Title = "Invisible",
    Value = false,
    Callback = function(v)
        pcall(function()
            if getgenv().PH_SetInvisible then
                getgenv().PH_SetInvisible(v)
            end
        end)
        notify("Player", v and "Invisible ON" or "Invisible OFF")
    end,
})

PlayerChar:Slider({
    Title = "Invis Range",
    Step = 1,
    Value = { Min = 1, Max = 9, Default = 9 },
    Callback = function(v)
        pcall(function()
            if getgenv().PH_SetInvisRange then
                getgenv().PH_SetInvisRange(v)
            end
        end)
    end,
})

PlayerTP:Button({
    Title = "Teleport to Map",
    Callback = function()
        pcall(function()
            if getgenv().PH_TeleportToMap then
                getgenv().PH_TeleportToMap()
            end
        end)
    end,
})

PlayerTP:Button({
    Title = "Teleport to Lobby",
    Callback = function()
        pcall(function()
            if getgenv().PH_TeleportToLobby then
                getgenv().PH_TeleportToLobby()
            end
        end)
    end,
})

PlayerTP:Toggle({
    Title = "Click TP (Tool)",
    Value = false,
    Callback = function(v)
        pcall(function()
            if getgenv().PH_SetClickTP then
                getgenv().PH_SetClickTP(v)
            end
        end)
        notify("Teleport", v and "Click TP ON - equip tp tool" or "Click TP OFF")
    end,
})

CombatSheriff:Button({
    Title = "Big Boom (Sheriff)",
    Callback = function()
        task.spawn(function()
            pcall(function()
                if getgenv().PH_BigBoomSheriff then
                    getgenv().PH_BigBoomSheriff()
                end
            end)
        end)
    end,
})

CombatSheriff:Toggle({
    Title = "Auto Grab Gun",
    Value = false,
    Callback = function(v)
        AutoGrab = v
        if v then
            refreshPlayerStatus()
            if PlayerStatus == "Match" and Workspace:FindFirstChild("GunDrop", true) and not hasGun() then
                task.spawn(GrabGun)
            end
        end
    end,
})

CombatSheriff:Toggle({
    Title = "Gun Notify",
    Value = false,
    Callback = function(v) GunNotify = v end,
})

CombatSheriff:Toggle({
    Title = "Success Notify",
    Value = false,
    Callback = function(v) SuccessNotify = v end,
})

CombatSheriff:Button({
    Title = "Grab Gun",
    Callback = function()
        task.spawn(function() GrabGun(true) end)
    end,
})

CombatSheriff:Button({
    Title = "Status",
    Callback = function()
        local has = hasGun()
        local drop = Workspace:FindFirstChild("GunDrop", true)
        notify("Status", has and "Gun in inventory" or (drop and "GunDrop on map" or "No gun"))
    end,
})

CombatMurder:Button({
    Title = "Kill All",
    Callback = function()
        killAll()
    end,
})

CombatMurder:Button({
    Title = "Big Boom (Murder)",
    Callback = function()
        task.spawn(function()
            pcall(function()
                if getgenv().PH_BigBoomMurder then
                    getgenv().PH_BigBoomMurder()
                end
            end)
        end)
    end,
})

CombatMurder:Button({
    Title = "Kill Sheriff",
    Callback = function()
        killSheriff()
    end,
})

CombatMurder:Button({
    Title = "Throw Knife (Nearest)",
    Callback = function()
        throwKnife()
    end,
})

CombatMurder:Toggle({
    Title = "Auto Throw Nearest",
    Value = false,
    Callback = function(v)
        AutoThrowEnabled = v
    end,
})

CombatMurder:Toggle({
    Title = "Auto Kill All",
    Value = false,
    Callback = function(v)
        AutoKillAllEnabled = v
    end,
})

CombatMurder:Toggle({
    Title = "Kill Aura",
    Value = false,
    Callback = function(v)
        pcall(function()
            if getgenv().PH_SetKillAura then
                getgenv().PH_SetKillAura(v)
            end
        end)
        notify("Combat", v and "Kill Aura ON" or "Kill Aura OFF")
    end,
})

CombatMurder:Slider({
    Title = "Kill Aura Distance",
    Step = 1,
    Value = { Min = 5, Max = 60, Default = 30 },
    Callback = function(v)
        pcall(function()
            if getgenv().PH_SetKillAuraDistance then
                getgenv().PH_SetKillAuraDistance(v)
            end
        end)
    end,
})

EspMain:Toggle({
    Title = "ESP Master",
    Value = false,
    Callback = function(v)
        ESPMaster = v
        if not v then
            clearAllESP()
        else
            refreshRoles()
            for _, plr in ipairs(Players:GetPlayers()) do
                if plr ~= LocalPlayer then createESP(plr) end
            end
        end
    end,
})

EspMain:Toggle({
    Title = "Names (ESP)",
    Value = false,
    Callback = function(v) espSettings.ESP.Enabled = v end,
})

EspMain:Toggle({
    Title = "Chams",
    Value = false,
    Callback = function(v) espSettings.Chams.Enabled = v end,
})

EspMain:Toggle({
    Title = "Tracers",
    Value = false,
    Callback = function(v) espSettings.Tracers.Enabled = v end,
})

EspMain:Toggle({
    Title = "Gun ESP",
    Value = true,
    Callback = function(v)
        espSettings.ESP.Gun = v
        espSettings.Chams.Gun = v
        espSettings.Tracers.Gun = v
    end,
})

EspMain:Toggle({
    Title = "Show Murderer",
    Value = true,
    Callback = function(v)
        espSettings.ESP.Murderer = v
        espSettings.Chams.Murderer = v
        espSettings.Tracers.Murderer = v
    end,
})

EspMain:Toggle({
    Title = "Show Sheriff/Hero",
    Value = true,
    Callback = function(v)
        espSettings.ESP.Sheriff = v
        espSettings.Chams.Sheriff = v
        espSettings.Tracers.Sheriff = v
    end,
})

EspMain:Toggle({
    Title = "Show Innocent",
    Value = true,
    Callback = function(v)
        espSettings.ESP.Innocent = v
        espSettings.Chams.Innocent = v
        espSettings.Tracers.Innocent = v
    end,
})

EspMain:Toggle({
    Title = "Show Everyone",
    Value = false,
    Callback = function(v)
        espSettings.ESP.Everyone = v
        espSettings.Chams.Everyone = v
        espSettings.Tracers.Everyone = v
    end,
})

EspColors:Colorpicker({
    Title = "Murderer Color",
    Default = Color3.fromRGB(255, 80, 80),
    Callback = function(c) espSettings.MurdererColor = c end,
})

EspColors:Colorpicker({
    Title = "Sheriff Color",
    Default = Color3.fromRGB(80, 140, 255),
    Callback = function(c) espSettings.SheriffColor = c end,
})

EspColors:Colorpicker({
    Title = "Hero Color",
    Default = Color3.fromRGB(255, 215, 0),
    Callback = function(c) espSettings.HeroColor = c end,
})

EspColors:Colorpicker({
    Title = "Innocent Color",
    Default = Color3.fromRGB(170, 255, 170),
    Callback = function(c) espSettings.InnocentColor = c end,
})

EspColors:Colorpicker({
    Title = "Gun Color",
    Default = Color3.fromRGB(255, 220, 0),
    Callback = function(c)
        espSettings.GunColor = c
    end,
})

VisualAura:Toggle({
    Title = "Self Aura",
    Value = false,
    Callback = function(v)
        SelfAuraEnabled = v
        if v then refreshSelfAura() else clearSelfAura() end
    end,
})

VisualAura:Dropdown({
    Title = "Aura Type",
    Values = PARTICLE_AURA_NAMES,
    Value = "starlight",
    Callback = function(opt)
        SelfAuraType = type(opt) == "table" and (opt.Title or opt[1] or opt) or opt
        if SelfAuraEnabled then refreshSelfAura() end
    end,
})

VisualAura:Colorpicker({
    Title = "Aura Color",
    Default = Color3.fromRGB(133, 220, 255),
    Callback = function(c)
        SelfAuraColor = c
        if SelfAuraEnabled then refreshSelfAura() end
    end,
})

VisualChar:Toggle({
    Title = "China Hat",
    Value = false,
    Callback = function(v)
        ChinaHatEnabled = v
        if v then
            createChinaHat(LocalPlayer.Character)
        else
            destroyChinaHat()
        end
    end,
})

VisualChar:Colorpicker({
    Title = "China Hat Color",
    Default = Color3.fromRGB(255, 105, 180),
    Callback = function(c)
        ChinaHatColor = c
        if chinaHatPart and chinaHatPart.Parent then
            chinaHatPart.Color = c
            local light = chinaHatPart:FindFirstChildOfClass("PointLight")
            if light then light.Color = c end
        elseif ChinaHatEnabled then
            createChinaHat(LocalPlayer.Character)
        end
    end,
})

VisualBeam:Toggle({
    Title = "Gun Beam",
    Value = false,
    Callback = function(v)
        pcall(function()
            if getgenv().PH_SetBulletTracer then
                getgenv().PH_SetBulletTracer(v)
            end
        end)
        notify("Visuals", v and "Gun Beam ON" or "Gun Beam OFF")
    end,
})

VisualBeam:Colorpicker({
    Title = "Gun Beam Color",
    Default = Color3.fromRGB(255, 200, 50),
    Callback = function(c)
        pcall(function()
            if getgenv().PH_SetBulletTracerColor then
                getgenv().PH_SetBulletTracerColor(c)
            end
        end)
    end,
})

VisualBeam:Slider({
    Title = "Gun Beam Thickness",
    Step = 0.1,
    Value = { Min = 0.5, Max = 6, Default = 2.5 },
    Callback = function(v)
        pcall(function()
            if getgenv().PH_SetBulletTracerThickness then
                getgenv().PH_SetBulletTracerThickness(v)
            end
        end)
    end,
})

VisualBeam:Slider({
    Title = "Gun Beam Duration",
    Step = 0.1,
    Value = { Min = 0.1, Max = 5, Default = 1.2 },
    Callback = function(v)
        pcall(function()
            if getgenv().PH_SetBulletTracerDuration then
                getgenv().PH_SetBulletTracerDuration(v)
            end
        end)
    end,
})

VisualChar:Toggle({
    Title = "Landing Circle",
    Value = false,
    Callback = function(v)
        pcall(function()
            if getgenv().PH_SetLandingCircle then
                getgenv().PH_SetLandingCircle(v)
            end
        end)
        notify("Visuals", v and "Landing Circle ON" or "Landing Circle OFF")
    end,
})

VisualChar:Colorpicker({
    Title = "Landing Circle Color",
    Default = Color3.fromRGB(255, 255, 255),
    Callback = function(c)
        pcall(function()
            if getgenv().PH_SetLandingCircleColor then
                getgenv().PH_SetLandingCircleColor(c)
            end
        end)
    end,
})

VisualChar:Slider({
    Title = "Landing Circle Opacity",
    Step = 0.05,
    Value = { Min = 0, Max = 1, Default = 1 },
    Callback = function(v)
        pcall(function()
            if getgenv().PH_SetLandingCircleTr then
                getgenv().PH_SetLandingCircleTr(v)
            end
        end)
    end,
})

VisualChar:Slider({
    Title = "Landing Circle Duration",
    Step = 0.05,
    Value = { Min = 0.1, Max = 3, Default = 0.82 },
    Callback = function(v)
        pcall(function()
            if getgenv().PH_SetLandingCircleDur then
                getgenv().PH_SetLandingCircleDur(v)
            end
        end)
    end,
})

ShaderSky:Toggle({
    Title = "Enable Skybox",
    Value = false,
    Callback = function(v)
        SkyboxEnabled = v
        if v then
            Skybox_Apply(CurrentSkybox)
        else
            Skybox_RestoreDefault()
        end
    end,
})

ShaderSky:Dropdown({
    Title = "Select Skybox",
    Values = skyboxList,
    Callback = function(opt)
        local name = type(opt) == "table" and (opt.Title or opt[1] or opt) or opt
        if not name or name == "" then return end
        CurrentSkybox = name
        if SkyboxEnabled then
            Skybox_Apply(CurrentSkybox)
        end
    end,
})

ShaderSky:Button({
    Title = "Restore Default Sky",
    Callback = function()
        SkyboxEnabled = false
        Skybox_RestoreDefault()
        notify("SkyBox", "Sky reset")
    end,
})

pcall(function()
    ShaderMain:Toggle({
        Title = "Fullbright",
        Value = false,
        Callback = function(v)
            pcall(function() if getgenv().PH_SetFullbright then getgenv().PH_SetFullbright(v) end end)
        end,
    })
    ShaderMain:Toggle({
        Title = "World Effects",
        Value = false,
        Callback = function(v)
            pcall(function() if getgenv().PH_SetWorldFX then getgenv().PH_SetWorldFX(v) end end)
        end,
    })
    ShaderMain:Dropdown({
        Title = "FX Preset",
        Values = {"Snow", "Sakura"},
        Callback = function(opt)
            local name = type(opt) == "table" and (opt[1] or opt.Title or opt) or opt
            pcall(function() if getgenv().PH_SetWorldFXType then getgenv().PH_SetWorldFXType(name) end end)
        end,
    })
    ShaderMain:Colorpicker({
        Title = "FX Color",
        Default = Color3.fromRGB(150, 200, 255),
        Callback = function(c)
            pcall(function() if getgenv().PH_SetWorldFXColor then getgenv().PH_SetWorldFXColor(c) end end)
        end,
    })
    ShaderMain:Slider({
        Title = "FX Range",
        Step = 1,
        Value = { Min = 20, Max = 900, Default = 250 },
        Callback = function(v)
            pcall(function() if getgenv().PH_SetWorldFXRate then getgenv().PH_SetWorldFXRate(v) end end)
        end,
    })
end)

ShaderMain:Dropdown({
    Title = "Time Shader",
    Values = {"Lite", "Morning", "Midday", "Afternoon", "Evening", "Night", "Midnight"},
    Callback = function(opt)
        local name = type(opt) == "table" and (opt.Title or opt[1] or opt) or opt
        if not name or name == "" then return end
        if name == "Lite" then
            resetShader()
            return
        end
        if ShaderPresets[name] then
            applyShaderPreset(ShaderPresets[name])
            notify("Shader", name)
        end
    end,
})

ShaderMain:Dropdown({
    Title = "Weather Shader",
    Values = {"Lite", "Sunny", "Rain", "Snow", "Fog", "Storm"},
    Callback = function(opt)
        local name = type(opt) == "table" and (opt.Title or opt[1] or opt) or opt
        if not name or name == "" then return end
        if name == "Lite" then
            resetShader()
            return
        end
        if ShaderPresets[name] then
            applyShaderPreset(ShaderPresets[name])
            notify("Shader", name)
        end
    end,
})

ShaderMain:Dropdown({
    Title = "Color Shader",
    Values = {"Lite", "Red", "Blue", "Green", "Purple", "Pink"},
    Callback = function(opt)
        local name = type(opt) == "table" and (opt.Title or opt[1] or opt) or opt
        if not name or name == "" then return end
        if name == "Lite" then
            resetShader()
            return
        end
        if ShaderPresets[name] then
            applyShaderPreset(ShaderPresets[name])
            notify("Shader", name)
        end
    end,
})

do
    local LP = LocalPlayer
    local Camera = Workspace.CurrentCamera
    local crosshair_lines = {}
    local crosshair_enabled = false
    local crosshair_hidden_game_cursor = false
    local original_cursor_icon = nil
    local gun_equipped = false
    local game_crosshair_gui = nil
    local gap_size = 4
    local line_length = 8
    local line_thickness = 2
    local line_color = Color3.fromRGB(255, 255, 255)
    local rotation_speed = 0
    local current_rotation = 0
    local crosshair_connection = nil
    local gun_watch_connections = {}
    local crosshair_angles = { 0, 0, 0, 0 }

    local function has_gun_equipped()
        local char = LP.Character
        return char and char:FindFirstChild("Gun") ~= nil
    end

    local function create_crosshair_lines()
        if not (type(Drawing) == "table" and type(Drawing.new) == "function") then return end
        for i = 1, 8 do
            local line = Drawing.new("Line")
            line.Visible = false
            line.Color = (i % 2 == 0) and Color3.fromRGB(0, 0, 0) or line_color
            line.Thickness = (i % 2 == 0) and (line_thickness + 2) or line_thickness
            line.Transparency = 1
            crosshair_lines[i] = line
        end
    end

    local function destroy_crosshair_lines()
        for i = 1, #crosshair_lines do
            if crosshair_lines[i] then
                pcall(function() crosshair_lines[i]:Remove() end)
                crosshair_lines[i] = nil
            end
        end
    end

    local function update_crosshair_visibility(show)
        local should_show = show and crosshair_enabled and gun_equipped
        for i = 1, #crosshair_lines do
            if crosshair_lines[i] then
                crosshair_lines[i].Visible = should_show
            end
        end
    end

    local function hide_game_crosshair_gui()
        pcall(function()
            local pg = LP:FindFirstChild("PlayerGui")
            local topbar = pg and pg:FindFirstChild("TopbarStandard")
            local crosshair = topbar and topbar:FindFirstChild("Crosshair")
            if crosshair and crosshair:IsA("GuiObject") then
                game_crosshair_gui = crosshair
                crosshair.Visible = false
            end
        end)
    end

    local function show_game_crosshair_gui()
        if game_crosshair_gui and game_crosshair_gui.Parent then
            pcall(function()
                if game_crosshair_gui:IsA("GuiObject") then
                    game_crosshair_gui.Visible = true
                end
            end)
        end
    end

    local function hide_game_cursor(hide)
        pcall(function()
            if hide then
                if not original_cursor_icon then
                    original_cursor_icon = UserInputService.MouseIcon
                end
                UserInputService.MouseIcon = ""
                hide_game_crosshair_gui()
            else
                if original_cursor_icon then
                    UserInputService.MouseIcon = original_cursor_icon
                end
                if not crosshair_enabled then
                    show_game_crosshair_gui()
                end
            end
        end)
    end

    local function update_crosshair()
        if not crosshair_enabled or #crosshair_lines == 0 then return end
        Camera = Workspace.CurrentCamera
        if not Camera then return end
        local vp = Camera.ViewportSize
        local cx, cy = vp.X / 2, vp.Y / 2
        if rotation_speed ~= 0 then
            current_rotation = current_rotation + rotation_speed * 0.016
        end
        local angles = {0, 90, 180, 270}
        for i = 1, 4 do
            local ang = math.rad(angles[i] + current_rotation)
            local cos, sin = math.cos(ang), math.sin(ang)
            local x1 = cx + cos * gap_size
            local y1 = cy + sin * gap_size
            local x2 = cx + cos * (gap_size + line_length)
            local y2 = cy + sin * (gap_size + line_length)
            local idx = (i - 1) * 2 + 1
            if crosshair_lines[idx] then
                crosshair_lines[idx].From = Vector2.new(x1, y1)
                crosshair_lines[idx].To = Vector2.new(x2, y2)
                crosshair_lines[idx].Color = line_color
            end
            if crosshair_lines[idx + 1] then
                crosshair_lines[idx + 1].From = Vector2.new(x1, y1)
                crosshair_lines[idx + 1].To = Vector2.new(x2, y2)
            end
        end
        update_crosshair_visibility(true)
    end

    local function start_crosshair()
        if #crosshair_lines == 0 then create_crosshair_lines() end
        gun_equipped = has_gun_equipped()
        if crosshair_connection then
            pcall(function() crosshair_connection:Disconnect() end)
        end
        crosshair_connection = RunService.RenderStepped:Connect(update_crosshair)
        for _, conn in ipairs(gun_watch_connections) do
            pcall(function() conn:Disconnect() end)
        end
        gun_watch_connections = {}
        local function watch(char)
            if not char then return end
            gun_watch_connections[#gun_watch_connections + 1] = char.ChildAdded:Connect(function(ch)
                if ch.Name == "Gun" then
                    gun_equipped = true
                    if crosshair_hidden_game_cursor then hide_game_cursor(true) end
                end
            end)
            gun_watch_connections[#gun_watch_connections + 1] = char.ChildRemoved:Connect(function(ch)
                if ch.Name == "Gun" then
                    gun_equipped = has_gun_equipped()
                    if not gun_equipped then hide_game_cursor(false) end
                end
            end)
        end
        if LP.Character then watch(LP.Character) end
        gun_watch_connections[#gun_watch_connections + 1] = LP.CharacterAdded:Connect(function(c)
            task.wait(0.1)
            gun_equipped = has_gun_equipped()
            watch(c)
        end)
        if gun_equipped and crosshair_hidden_game_cursor then
            hide_game_cursor(true)
        end
    end

    local function stop_crosshair()
        if crosshair_connection then
            pcall(function() crosshair_connection:Disconnect() end)
            crosshair_connection = nil
        end
        for _, conn in ipairs(gun_watch_connections) do
            pcall(function() conn:Disconnect() end)
        end
        gun_watch_connections = {}
        update_crosshair_visibility(false)
        hide_game_cursor(false)
        show_game_crosshair_gui()
        destroy_crosshair_lines()
    end

    getgenv().Crosshair = {
        enable = function(v)
            crosshair_enabled = v and true or false
            if crosshair_enabled then start_crosshair() else stop_crosshair() end
        end,
        setHideOriginal = function(v)
            crosshair_hidden_game_cursor = v and true or false
            if gun_equipped and crosshair_enabled then
                hide_game_cursor(crosshair_hidden_game_cursor)
            end
        end,
        setGap = function(v) gap_size = v end,
        setLength = function(v) line_length = v end,
        setThickness = function(v)
            line_thickness = v
            for i = 1, #crosshair_lines do
                if crosshair_lines[i] then
                    crosshair_lines[i].Thickness = (i % 2 == 0) and v + 2 or v
                end
            end
        end,
        setColor = function(c) line_color = c end,
        setRotation = function(v) rotation_speed = v end,
    }
end

CombatFling:Button({
    Title = "Fling Murderer",
    Callback = function()
        local t = fling_role("Murderer")
        if not t then
            notify("Fling", "Murderer not found")
            return
        end
        notify("Fling", "Flinging Murderer...")
        task.spawn(do_fling, t)
    end,
})

CombatFling:Button({
    Title = "Fling Sheriff",
    Callback = function()
        local t = fling_role("Sheriff")
        if not t then
            notify("Fling", "Sheriff not found")
            return
        end
        notify("Fling", "Flinging Sheriff...")
        task.spawn(do_fling, t)
    end,
})

CombatFling:Toggle({
    Title = "Anti Fling",
    Value = false,
    Callback = function(v)
        setAntiFling(v)
        notify("Fling", v and "Anti Fling ON" or "OFF")
    end,
})

CombatGunMorph:Dropdown({
    Title = "Skin",
    Options = { "None", "Shotgun (Classic)" },
    Default = "None",
    Callback = function(v)
        pcall(function()
            if v == "None" or v == nil then
                if getgenv().PH_SetGunMorph then
                    getgenv().PH_SetGunMorph(false)
                end
                notify("Gun Morph", "OFF")
                return
            end
            local skins = {
                ["Shotgun (Classic)"] = {
                    Id = 2374456368,
                    Grip = Vector3.new(-90, 180, -180),
                },
            }
            local cfg = skins[v]
            if cfg and getgenv().PH_SetGunMorph then
                if getgenv().PH_SetGunMorphGrip then
                    getgenv().PH_SetGunMorphGrip(nil, cfg.Grip)
                end
                getgenv().PH_SetGunMorph(true, cfg.Id, v)
                notify("Gun Morph", v .. " ON")
            end
        end)
    end,
})

CombatGunMorph:Textbox({
    Title = "Custom Mesh ID",
    Default = "2374456368",
    Placeholder = "asset id",
    Callback = function(text)
        local n = tonumber(text)
        if n then
            pcall(function()
                if getgenv().PH_SetGunMorphId then
                    getgenv().PH_SetGunMorphId(n)
                end
                if getgenv().PH_SetGunMorph then
                    getgenv().PH_SetGunMorph(true, n, "Custom")
                end
            end)
            notify("Gun Morph", "Custom ID = " .. tostring(n))
        end
    end,
})

CombatGunMorph:Button({
    Title = "Apply Morph Now",
    Callback = function()
        pcall(function()
            if getgenv().PH_ApplyGunMorph then
                getgenv().PH_ApplyGunMorph()
            end
        end)
    end,
})

CombatSheriff:Toggle({
    Title = "Silent Aim",
    Value = false,
    Callback = function(v)
        local S = getgenv().SILENT_S
        if not S then
            notify("Combat", "Silent Aim not loaded")
            return
        end
        S.enabled = v and true or false
        getgenv().SILENT_AIM_ACTIVE = S.enabled
        if S.enabled then
            local fn = getgenv().SILENT_INSTALL_HOOKS
            if type(fn) == "function" then
                pcall(fn)
            end
            notify("Combat", "Silent Aim ON")
        else
            notify("Combat", "Silent Aim OFF")
        end
    end,
})

CombatSheriff:Toggle({
    Title = "Prediction",
    Value = true,
    Callback = function(v)
        local S = getgenv().SILENT_S
        if S then
            S.predict = v and true or false
        end
    end,
})

CombatSheriff:Toggle({
    Title = "Force Shoot",
    Value = false,
    Callback = function(v)
        local S = getgenv().SILENT_S
        if S then
            S.force = v and true or false
        end
    end,
})

CombatSheriff:Slider({
    Title = "Force Origin",
    Step = 1,
    Value = { Min = 0, Max = 40, Default = 15 },
    Callback = function(v)
        local S = getgenv().SILENT_S
        if S then
            S.stand_off = v
        end
    end,
})

CombatSheriff:Toggle({
    Title = "Auto Shoot",
    Value = false,
    Callback = function(v)
        local S = getgenv().SILENT_S
        if S then
            S.auto_on = v and true or false
        end
    end,
})

CombatSheriff:Slider({
    Title = "Auto Delay (ms)",
    Step = 10,
    Value = { Min = 0, Max = 600, Default = 0 },
    Callback = function(v)
        local S = getgenv().SILENT_S
        if S then
            S.auto_delay = (tonumber(v) or 0) / 1000
        end
    end,
})

do
    local fov_on, fov_value = false, 70
    local fov_original, fov_conn = nil, nil

    local function setCustomFov(v)
        fov_on = v and true or false
        local cam = Workspace.CurrentCamera
        if fov_on then
            if cam then
                fov_original = cam.FieldOfView
                cam.FieldOfView = fov_value
            end
            if not fov_conn then
                fov_conn = RunService.RenderStepped:Connect(function()
                    if not fov_on then return end
                    local camera = Workspace.CurrentCamera
                    if camera and camera.FieldOfView ~= fov_value then
                        camera.FieldOfView = fov_value
                    end
                end)
            end
        else
            if cam and fov_original then
                cam.FieldOfView = fov_original
            end
            if fov_conn then
                pcall(function() fov_conn:Disconnect() end)
                fov_conn = nil
            end
        end
    end

    pcall(function()
        LocalPlayer.CharacterAdded:Connect(function()
            task.wait(0.1)
            if fov_on then
                local cam = Workspace.CurrentCamera
                if cam then
                    if not fov_original then fov_original = cam.FieldOfView end
                    cam.FieldOfView = fov_value
                end
            end
        end)
    end)

    local function cham_cache_part(cache, part)
        if not cache[part] then
            cache[part] = { mat = part.Material, col = part.Color, tr = part.Transparency }
        end
    end

    local function cham_restore(cache)
        for part, c in pairs(cache) do
            if part and part.Parent then
                pcall(function()
                    part.Material = c.mat
                    part.Color = c.col
                    part.Transparency = c.tr
                end)
            end
            cache[part] = nil
        end
        if type(table.clear) == "function" then
            table.clear(cache)
        end
    end

    local function cham_apply_part(cache, part, kind, col)
        if not part:IsA("BasePart") then return end
        cham_cache_part(cache, part)
        pcall(function()
            if kind == "ForceField" then
                part.Material = Enum.Material.ForceField
            elseif kind == "Flat" then
                part.Material = Enum.Material.SmoothPlastic
            else
                part.Material = Enum.Material.Neon
            end
            part.Color = col
        end)
    end

    local tc_on, tc_type, tc_col = false, "ForceField", Color3.fromRGB(255, 200, 0)
    local tc_cache, tc_conn = {}, nil

    local function tc_is_tool(obj)
        if not obj or not obj:IsA("Tool") then return false end
        local n = obj.Name
        return n == "Gun" or n == "Knife"
            or obj:FindFirstChild("GunClient") ~= nil
            or obj:FindFirstChild("KnifeClient") ~= nil
            or obj:FindFirstChild("Shoot") ~= nil
    end

    local function tc_scan()
        if not tc_on then return end
        local function scan(container)
            if not container then return end
            for _, ch in ipairs(container:GetChildren()) do
                if tc_is_tool(ch) then
                    for _, d in ipairs(ch:GetDescendants()) do
                        if d:IsA("BasePart") then
                            cham_apply_part(tc_cache, d, tc_type, tc_col)
                        end
                    end
                end
            end
        end
        scan(LocalPlayer.Character)
        scan(LocalPlayer:FindFirstChildOfClass("Backpack"))
    end

    local function setToolChams(v)
        tc_on = v and true or false
        if not tc_on then
            cham_restore(tc_cache)
            if tc_conn then
                pcall(function() tc_conn:Disconnect() end)
                tc_conn = nil
            end
            return
        end
        tc_scan()
        if not tc_conn then
            local acc = 0
            tc_conn = RunService.Heartbeat:Connect(function(dt)
                acc = acc + dt
                if acc < 0.25 then return end
                acc = 0
                if tc_on then tc_scan() end
            end)
        end
    end

    local sc_on, sc_type, sc_col = false, "ForceField", Color3.fromRGB(0, 200, 255)
    local sc_cache, sc_conn = {}, nil

    local function sc_scan()
        if not sc_on then return end
        local char = LocalPlayer.Character
        if not char then return end
        for _, d in ipairs(char:GetDescendants()) do
            if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" then
                cham_apply_part(sc_cache, d, sc_type, sc_col)
            end
        end
    end

    local function setSelfChams(v)
        sc_on = v and true or false
        if not sc_on then
            cham_restore(sc_cache)
            if sc_conn then
                pcall(function() sc_conn:Disconnect() end)
                sc_conn = nil
            end
            return
        end
        sc_scan()
        if not sc_conn then
            local acc = 0
            sc_conn = RunService.Heartbeat:Connect(function(dt)
                acc = acc + dt
                if acc < 0.3 then return end
                acc = 0
                if sc_on then sc_scan() end
            end)
        end
    end

    PlayerChar:Toggle({
        Title = "Custom FOV",
        Value = false,
        Callback = function(v)
            setCustomFov(v)
            notify("Player", v and "Custom FOV ON" or "Custom FOV OFF")
        end,
    })

    PlayerChar:Slider({
        Title = "FOV Value",
        Step = 1,
        Value = { Min = 30, Max = 120, Default = 70 },
        Callback = function(v)
            fov_value = v
            if fov_on then
                local cam = Workspace.CurrentCamera
                if cam then cam.FieldOfView = v end
            end
        end,
    })

    VisualChams:Toggle({
        Title = "Tool Chams",
        Value = false,
        Callback = function(v)
            setToolChams(v)
            notify("Visuals", v and "Tool Chams ON" or "Tool Chams OFF")
        end,
    })

    VisualChams:Dropdown({
        Title = "Tool Chams Type",
        Values = {"ForceField", "Flat", "Neon"},
        Callback = function(v)
            local name = type(v) == "table" and (v.Title or v[1] or v) or v
            if not name or name == "" then return end
            tc_type = name
            if tc_on then
                cham_restore(tc_cache)
                tc_scan()
            end
        end,
    })

    VisualChams:Colorpicker({
        Title = "Tool Chams Color",
        Default = Color3.fromRGB(255, 200, 0),
        Callback = function(c)
            tc_col = c
            if tc_on then
                cham_restore(tc_cache)
                tc_scan()
            end
        end,
    })

    VisualChams:Toggle({
        Title = "Self Chams",
        Value = false,
        Callback = function(v)
            setSelfChams(v)
            notify("Visuals", v and "Self Chams ON" or "Self Chams OFF")
        end,
    })

    VisualChams:Dropdown({
        Title = "Self Chams Type",
        Values = {"ForceField", "Flat", "Neon"},
        Callback = function(v)
            local name = type(v) == "table" and (v.Title or v[1] or v) or v
            if not name or name == "" then return end
            sc_type = name
            if sc_on then
                cham_restore(sc_cache)
                sc_scan()
            end
        end,
    })

    VisualChams:Colorpicker({
        Title = "Self Chams Color",
        Default = Color3.fromRGB(0, 200, 255),
        Callback = function(c)
            sc_col = c
            if sc_on then
                cham_restore(sc_cache)
                sc_scan()
            end
        end,
    })
end

do
    local SoundService = game:GetService("SoundService")
    local SND_LIST = { "primordial", "neverlose", "sparkle", "mc bow", "skeet", "break", "rust" }
    local SND_BASE_URL = "https://github.com/khenn791/lmao/raw/refs/heads/main/"
    local SND_CACHE = "pressurehub_sounds/"

    local snd_cfg = {
        sheriff = { on = false, name = "mc bow", volume = 1 },
        murder = { on = false, name = "skeet", volume = 1 },
    }
    local snd_cache = {}
    local snd_pool = {}
    local snd_hooked = {}
    local snd_last = { sheriff = 0, murder = 0 }
    local snd_alive = true
    local snd_watch_conns = {}
    local snd_watched_char, snd_watched_bp = nil, nil

    local function snd_fs_ready()
        return type(isfile) == "function"
            and type(writefile) == "function"
            and type(readfile) == "function"
            and type(getcustomasset) == "function"
    end

    local function snd_download(name)
        if not snd_fs_ready() then return nil end
        if type(isfolder) == "function" and type(makefolder) == "function" then
            pcall(function()
                if not isfolder(SND_CACHE) then makefolder(SND_CACHE) end
            end)
        end
        local path = SND_CACHE .. string.gsub(name, " ", "_") .. ".ogg"
        local ok_is, has = pcall(isfile, path)
        if not (ok_is and has) then
            local url = SND_BASE_URL .. string.gsub(name, " ", "%%20") .. ".ogg"
            local ok_dl, data = pcall(function()
                return game:HttpGet(url)
            end)
            if not ok_dl or type(data) ~= "string" or #data < 512 then
                return nil
            end
            if not pcall(writefile, path, data) then return nil end
        end
        local ok_as, asset = pcall(getcustomasset, path)
        if ok_as and type(asset) == "string" and asset ~= "" then
            return asset
        end
        return nil
    end

    local function snd_resolve(name)
        if snd_cache[name] ~= nil then
            return snd_cache[name] ~= false and snd_cache[name] or nil
        end
        local asset = snd_download(name)
        snd_cache[name] = asset or false
        return asset
    end

    local function snd_template(kind)
        local cfg = snd_cfg[kind]
        if not cfg then return nil end
        local id = snd_resolve(cfg.name)
        if not id then
            if snd_pool[kind] then
                pcall(function() snd_pool[kind]:Destroy() end)
                snd_pool[kind] = nil
            end
            return nil
        end
        local cur = snd_pool[kind]
        if cur and cur.Parent and cur.SoundId == id then
            pcall(function() cur.Volume = cfg.volume end)
            return cur
        end
        if cur then pcall(function() cur:Destroy() end) end
        local ok, s = pcall(function()
            local snd = Instance.new("Sound")
            snd.Name = "Kvant_KillSnd"
            snd.SoundId = id
            snd.Volume = cfg.volume
            snd.Looped = false
            snd.Parent = SoundService
            return snd
        end)
        if not ok or not s then
            snd_pool[kind] = nil
            return nil
        end
        snd_pool[kind] = s
        return s
    end

    local function snd_play(kind)
        local template = snd_pool[kind] or snd_template(kind)
        if not template then return end
        pcall(function()
            local c = template:Clone()
            c.Volume = snd_cfg[kind].volume
            c.Looped = false
            c.Parent = SoundService
            c:Play()
            task.delay(8, function()
                pcall(function() c:Destroy() end)
            end)
        end)
    end

    local function snd_kind_active(kind)
        local cfg = snd_cfg[kind]
        return cfg and cfg.on
    end

    local function snd_should_mute(kind)
        return snd_kind_active(kind) and snd_template(kind) ~= nil
    end

    local function snd_refresh()
        for inst, entry in pairs(snd_hooked) do
            if inst.Parent then
                pcall(function()
                    inst.Volume = snd_should_mute(entry.kind) and 0 or entry.vol
                end)
            end
        end
    end

    local function snd_hook(inst, kind)
        if snd_hooked[inst] then return end
        local entry = { kind = kind, vol = inst.Volume, conns = {} }
        snd_hooked[inst] = entry

        local function fire()
            if not snd_kind_active(kind) then return end
            if not snd_pool[kind] and not snd_template(kind) then return end
            if os.clock() - snd_last[kind] < 0.15 then return end
            snd_last[kind] = os.clock()
            pcall(function() inst:Stop() end)
            snd_play(kind)
        end

        entry.conns[#entry.conns + 1] = inst.Played:Connect(fire)
        entry.conns[#entry.conns + 1] = inst:GetPropertyChangedSignal("Playing"):Connect(function()
            if inst.Playing then fire() end
        end)
        entry.conns[#entry.conns + 1] = inst.Destroying:Connect(function()
            snd_hooked[inst] = nil
        end)

        pcall(function()
            inst.Volume = snd_should_mute(kind) and 0 or entry.vol
        end)
    end

    local function snd_tool_kind(tool)
        if tool:FindFirstChild("GunClient") or tool:FindFirstChild("Shoot") or tool.Name == "Gun" then
            return "sheriff"
        end
        if tool:FindFirstChild("KnifeClient") or tool:FindFirstChild("Events") or tool.Name == "Knife" then
            return "murder"
        end
        return nil
    end

    local function snd_consider(inst)
        if not inst:IsA("Sound") then return end
        if inst.Name ~= "GunKill" and inst.Name ~= "Kill" then return end
        local handle = inst.Parent
        if not handle or handle.Name ~= "Handle" then return end
        local tool = handle.Parent
        if not tool or not tool:IsA("Tool") then return end
        local kind = snd_tool_kind(tool)
        if kind then snd_hook(inst, kind) end
    end

    local function snd_clear_watch()
        for i = #snd_watch_conns, 1, -1 do
            pcall(function() snd_watch_conns[i]:Disconnect() end)
            snd_watch_conns[i] = nil
        end
        snd_watched_char, snd_watched_bp = nil, nil
    end

    local function snd_watch()
        local char = LocalPlayer.Character
        local bp = LocalPlayer:FindFirstChildOfClass("Backpack")
        if char == snd_watched_char and bp == snd_watched_bp then return end
        snd_clear_watch()
        snd_watched_char, snd_watched_bp = char, bp
        if char then
            snd_watch_conns[#snd_watch_conns + 1] = char.DescendantAdded:Connect(snd_consider)
        end
        if bp then
            snd_watch_conns[#snd_watch_conns + 1] = bp.DescendantAdded:Connect(snd_consider)
        end
    end

    local function snd_scan()
        snd_watch()
        local function scan(container)
            if not container then return end
            for _, tool in ipairs(container:GetChildren()) do
                if tool:IsA("Tool") then
                    local kind = snd_tool_kind(tool)
                    local handle = tool:FindFirstChild("Handle")
                    if kind and handle then
                        for _, child in ipairs(handle:GetChildren()) do
                            if child:IsA("Sound") and (child.Name == "GunKill" or child.Name == "Kill") then
                                snd_hook(child, kind)
                            end
                        end
                    end
                end
            end
        end
        scan(LocalPlayer.Character)
        scan(LocalPlayer:FindFirstChildOfClass("Backpack"))
    end

    local function snd_any_active()
        return snd_cfg.sheriff.on or snd_cfg.murder.on
    end

    task.spawn(function()
        while snd_alive do
            task.wait(0.4)
            if snd_alive and snd_any_active() then
                pcall(snd_scan)
                pcall(snd_refresh)
            end
        end
    end)

    CombatSounds:Toggle({
        Title = "Sheriff Kill Sound",
        Value = false,
        Callback = function(v)
            snd_cfg.sheriff.on = v and true or false
            if v then
                task.spawn(function()
                    snd_template("sheriff")
                    snd_scan()
                    snd_refresh()
                end)
                notify("Combat", "Sheriff Kill Sound ON")
            else
                snd_refresh()
                notify("Combat", "Sheriff Kill Sound OFF")
            end
        end,
    })

    CombatSounds:Dropdown({
        Title = "Sheriff Sound",
        Values = SND_LIST,
        Callback = function(v)
            local name = type(v) == "table" and (v.Title or v[1] or v) or v
            if not name or name == "" then return end
            snd_cfg.sheriff.name = name
            snd_pool.sheriff = nil
            if snd_cfg.sheriff.on then
                task.spawn(function()
                    snd_template("sheriff")
                    snd_refresh()
                end)
            end
        end,
    })

    CombatSounds:Slider({
        Title = "Sheriff Sound Volume",
        Step = 0.1,
        Value = { Min = 0.1, Max = 5, Default = 1 },
        Callback = function(v)
            snd_cfg.sheriff.volume = v
            if snd_pool.sheriff then
                pcall(function() snd_pool.sheriff.Volume = v end)
            end
        end,
    })

    CombatSounds:Toggle({
        Title = "Murder Kill Sound",
        Value = false,
        Callback = function(v)
            snd_cfg.murder.on = v and true or false
            if v then
                task.spawn(function()
                    snd_template("murder")
                    snd_scan()
                    snd_refresh()
                end)
                notify("Combat", "Murder Kill Sound ON")
            else
                snd_refresh()
                notify("Combat", "Murder Kill Sound OFF")
            end
        end,
    })

    CombatSounds:Dropdown({
        Title = "Murder Sound",
        Values = SND_LIST,
        Callback = function(v)
            local name = type(v) == "table" and (v.Title or v[1] or v) or v
            if not name or name == "" then return end
            snd_cfg.murder.name = name
            snd_pool.murder = nil
            if snd_cfg.murder.on then
                task.spawn(function()
                    snd_template("murder")
                    snd_refresh()
                end)
            end
        end,
    })

    CombatSounds:Slider({
        Title = "Murder Sound Volume",
        Step = 0.1,
        Value = { Min = 0.1, Max = 5, Default = 1 },
        Callback = function(v)
            snd_cfg.murder.volume = v
            if snd_pool.murder then
                pcall(function() snd_pool.murder.Volume = v end)
            end
        end,
    })
end

do
    local bt_on = false
    local bt_col = Color3.fromRGB(255, 60, 60)
    local bt_model = nil
    local BT_CAP = 128
    local cf0 = CFrame.new()
    local bt_hist = {}
    for i = 1, BT_CAP do
        bt_hist[i] = { 0, cf0 }
    end
    local bt_first = 1
    local bt_count = 0
    local bt_ping = 0.15
    local bt_ping_at = 0
    local bt_pairs = {}
    local bt_conn = nil
    local bt_char_conn = nil

    local function bt_read_ping()
        local ok, v = pcall(function()
            return game:GetService("Stats").Network.ServerStatsItem["Data Ping"]:GetValue() / 1000
        end)
        if ok and type(v) == "number" then return v end
        return 0.15
    end

    local function bt_destroy()
        if bt_model then
            if type(_G) == "table" and type(_G.BACKTRACK_CLONES) == "table" then
                _G.BACKTRACK_CLONES[bt_model] = nil
            end
            pcall(function() bt_model:Destroy() end)
            bt_model = nil
        end
        bt_pairs = {}
        bt_first = 1
        bt_count = 0
    end

    local function bt_build()
        bt_destroy()
        local char = LocalPlayer.Character
        if not char then return end
        local rhrp = char:FindFirstChild("HumanoidRootPart")
        if not rhrp then return end
        local was = char.Archivable
        char.Archivable = true
        local ok, m = pcall(function() return char:Clone() end)
        char.Archivable = was
        if not ok or not m then return end
        if type(_G) == "table" then
            _G.BACKTRACK_CLONES = _G.BACKTRACK_CLONES or {}
        end
        local rparts = {}
        for _, o in ipairs(char:GetDescendants()) do
            if o:IsA("BasePart") then
                rparts[#rparts + 1] = o
            end
        end
        local ci = 0
        for _, o in ipairs(m:GetDescendants()) do
            if o:IsA("Script") or o:IsA("LocalScript") then
                pcall(function() o:Destroy() end)
            elseif o:IsA("Decal") or o:IsA("Texture") or o:IsA("SurfaceAppearance") then
                pcall(function() o:Destroy() end)
            elseif o:IsA("ParticleEmitter") or o:IsA("Beam") or o:IsA("Trail")
                or o:IsA("PointLight") or o:IsA("SpotLight") or o:IsA("SurfaceLight") then
                pcall(function() o:Destroy() end)
            elseif o:IsA("BasePart") then
                o.Anchored = true
                o.CanCollide = false
                o.CanQuery = false
                o.Massless = true
                o.CastShadow = false
                if o.Name == "HumanoidRootPart" then
                    o.Transparency = 1
                else
                    o.Material = Enum.Material.ForceField
                    o.Color = bt_col
                    o.Transparency = 0
                end
                ci = ci + 1
                bt_pairs[#bt_pairs + 1] = { o, rparts[ci] }
            end
        end
        local hum = m:FindFirstChildOfClass("Humanoid")
        if hum then pcall(function() hum:Destroy() end) end
        m.Name = "Kvant_Backtrack"
        m.Parent = Workspace
        bt_model = m
        if type(_G) == "table" and type(_G.BACKTRACK_CLONES) == "table" then
            _G.BACKTRACK_CLONES[m] = true
        end
    end

    local function bt_update()
        local char = LocalPlayer.Character
        local rhrp = char and char:FindFirstChild("HumanoidRootPart")
        if not rhrp then return end
        if not bt_model then
            bt_build()
            if not bt_model then return end
        end
        if not bt_model.Parent then
            bt_model.Parent = Workspace
        end
        local now = os.clock()
        local base_cf = rhrp.CFrame
        if bt_count < BT_CAP then
            bt_count = bt_count + 1
        else
            bt_first = bt_first % BT_CAP + 1
        end
        local slot = bt_hist[(bt_first + bt_count - 2) % BT_CAP + 1]
        slot[1] = now
        slot[2] = base_cf
        if now - bt_ping_at >= 0.2 then
            bt_ping_at = now
            local ok, value = pcall(bt_read_ping)
            bt_ping = math.clamp((ok and value) or 0.15, 0.05, 0.6)
        end
        local target = now - bt_ping
        local cf = base_cf
        for k = bt_count, 1, -1 do
            local s = bt_hist[(bt_first + k - 2) % BT_CAP + 1]
            if s[1] <= target then
                cf = s[2]
                break
            end
        end
        while bt_count > 0 and bt_hist[bt_first][1] < now - 1 do
            bt_first = bt_first % BT_CAP + 1
            bt_count = bt_count - 1
        end
        local baseInv = rhrp.CFrame:Inverse()
        for i = 1, #bt_pairs do
            local cp, rp = bt_pairs[i][1], bt_pairs[i][2]
            if cp and cp.Parent and rp and rp.Parent then
                cp.CFrame = cf * (baseInv * rp.CFrame)
            end
        end
    end

    local function setBacktrack(v)
        bt_on = v and true or false
        if bt_on then
            pcall(bt_build)
            if not bt_conn then
                bt_conn = RunService.RenderStepped:Connect(function()
                    if bt_on then pcall(bt_update) end
                end)
            end
            if not bt_char_conn then
                bt_char_conn = LocalPlayer.CharacterAdded:Connect(function()
                    task.wait(0.3)
                    if bt_on then pcall(bt_build) end
                end)
            end
        else
            if bt_conn then
                pcall(function() bt_conn:Disconnect() end)
                bt_conn = nil
            end
            bt_destroy()
        end
    end

    VisualTrack:Toggle({
        Title = "Backtrack",
        Value = false,
        Callback = function(v)
            setBacktrack(v)
            notify("Visuals", v and "Backtrack ON" or "Backtrack OFF")
        end,
    })

    VisualTrack:Colorpicker({
        Title = "Backtrack Color",
        Default = Color3.fromRGB(255, 60, 60),
        Callback = function(c)
            bt_col = c
            if bt_model then
                for _, p in ipairs(bt_model:GetDescendants()) do
                    if p:IsA("BasePart") and p.Name ~= "HumanoidRootPart" then
                        p.Color = c
                    end
                end
            end
        end,
    })
end

pcall(function()
    local CollectionService = game:GetService("CollectionService")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local PlayersSvc = game:GetService("Players")
    local WorkspaceSvc = game:GetService("Workspace")
    local RunSvc = game:GetService("RunService")
    local LP = PlayersSvc.LocalPlayer

    local autofarm_on = false
    local autoreset_on = false
    local coins_done = false
    local saw_coins = false
    local farm_target = nil
    local nc_cache = {}
    local FARM_SPEED = 23
    local round_mod = nil
    local farm_mode = "Basic"
    local avoid_murder = false
    local was_down = false
    local down_ref_y = nil
    local last_touch = 0
    local DOWN_DEPTH = 14
    local DOWN_RISE_XZ = 4
    local AVOID_DIST = 40
    local RISE_SAFE_DIST = 20
    local farm_conn = nil

    local function farm_hrp()
        local c = LP.Character
        return c and c:FindFirstChild("HumanoidRootPart")
    end

    local function get_round_data()
        if not round_mod then
            local ok, m = pcall(function()
                return require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("CurrentRoundClient"))
            end)
            if ok and type(m) == "table" then
                round_mod = m
            end
        end
        return round_mod and round_mod.PlayerData
    end

    local function can_farm()
        local char = LP.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if not hum or hum.Health <= 0 then
            return false
        end
        local d = get_round_data()
        if type(d) == "table" then
            local me = d[LP.Name]
            if not me or not me.Role or me.Dead then
                return false
            end
        end
        return true
    end

    local function coin_bags_full()
        local pg = LP:FindFirstChild("PlayerGui")
        local main = pg and pg:FindFirstChild("MainGUI")
        local gg = main and main:FindFirstChild("Game")
        local bags = gg and gg:FindFirstChild("CoinBags")
        local container = bags and bags:FindFirstChild("Container")
        if not container then
            return false
        end
        local any = false
        for _, v in ipairs(container:GetChildren()) do
            if v:IsA("Frame") and v.Visible then
                any = true
                local full = v:FindFirstChild("Full")
                if not (full and full.Visible) then
                    return false
                end
            end
        end
        return any
    end

    local function reset_farm_progress()
        coins_done = false
        saw_coins = false
        farm_target = nil
    end

    task.spawn(function()
        local ok, remote = pcall(function()
            return ReplicatedStorage:WaitForChild("Remotes", 10)
                and ReplicatedStorage.Remotes:WaitForChild("Gameplay", 10)
                and ReplicatedStorage.Remotes.Gameplay:WaitForChild("CoinsStarted", 15)
        end)
        if ok and remote then
            pcall(function()
                remote.OnClientEvent:Connect(reset_farm_progress)
            end)
        end
    end)

    pcall(function()
        LP.CharacterAdded:Connect(function()
            reset_farm_progress()
        end)
    end)

    local function coin_available(v)
        return v and v.Parent and v:IsA("BasePart") and not v:GetAttribute("Collected") and not v:GetAttribute("Delete")
    end

    local function nearest_coin(pos, list)
        local best, bd = nil, math.huge
        for _, v in ipairs(list) do
            local d = (v.Position - pos).Magnitude
            if d < bd then
                bd = d
                best = v
            end
        end
        return best
    end

    local function set_farm_noclip(on)
        local char = LP.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if on then
            if not char then return end
            if hum then
                pcall(function() hum.PlatformStand = true end)
            end
            for _, p in ipairs(char:GetDescendants()) do
                if p:IsA("BasePart") and p.CanCollide then
                    if nc_cache[p] == nil then nc_cache[p] = true end
                    p.CanCollide = false
                end
            end
        else
            if hum then
                pcall(function() hum.PlatformStand = false end)
            end
            for p, _ in pairs(nc_cache) do
                if p and p.Parent then
                    pcall(function() p.CanCollide = true end)
                end
            end
            nc_cache = {}
        end
    end

    local up_params = RaycastParams.new()
    up_params.FilterType = Enum.RaycastFilterType.Exclude
    up_params.IgnoreWater = true

    local function return_to_surface()
        local hrp = farm_hrp()
        if not hrp then return end
        local origin = hrp.Position
        up_params.FilterDescendantsInstances = { LP.Character }
        local res = WorkspaceSvc:Raycast(origin, Vector3.new(0, 400, 0), up_params)
        local y = res and (res.Position.Y + 5) or (down_ref_y and down_ref_y + 5 or nil)
        if not y then return end
        pcall(function()
            hrp.CFrame = CFrame.new(origin.X, y, origin.Z)
            hrp.AssemblyLinearVelocity = Vector3.zero
            hrp.AssemblyAngularVelocity = Vector3.zero
        end)
    end

    local function farm_release()
        if was_down then
            was_down = false
            return_to_surface()
        end
        set_farm_noclip(false)
    end

    local murder_hrp_cache, murder_hrp_t = nil, 0
    local function murderer_hrp()
        local now = os.clock()
        if now - murder_hrp_t < 0.25 then return murder_hrp_cache end
        murder_hrp_t = now
        murder_hrp_cache = nil
        local d = get_round_data()
        if type(d) == "table" then
            local me = d[LP.Name]
            if me and me.Role == "Murderer" then return nil end
            for name, info in pairs(d) do
                if type(info) == "table" and info.Role == "Murderer" and not info.Dead and name ~= LP.Name then
                    local pl = PlayersSvc:FindFirstChild(name)
                    local char = pl and pl.Character
                    local h = char and char:FindFirstChild("HumanoidRootPart")
                    local hum = char and char:FindFirstChildOfClass("Humanoid")
                    if h and (not hum or hum.Health > 0) then
                        murder_hrp_cache = h
                    end
                    break
                end
            end
        end
        return murder_hrp_cache
    end

    local function flat_dist(a, b)
        return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
    end

    local function pick_coin(pos, list, mpos)
        if not (avoid_murder and mpos) then
            return nearest_coin(pos, list)
        end
        local safe, sd = nil, math.huge
        local far, fd = nil, -1
        for _, v in ipairs(list) do
            local md = flat_dist(v.Position, mpos)
            if md > fd then fd = md far = v end
            if md >= AVOID_DIST then
                local d = (v.Position - pos).Magnitude
                if d < sd then sd = d safe = v end
            end
        end
        if safe then return safe end
        if far and fd >= AVOID_DIST * 0.6 then return far end
        return nil
    end

    local function coin_ok_now(v, mpos)
        if not coin_available(v) then return false end
        if avoid_murder and mpos and flat_dist(v.Position, mpos) < AVOID_DIST * 0.6 then return false end
        return true
    end

    local function avoid_steer(cur, dest, mpos)
        if not (avoid_murder and mpos) then return dest end
        local dm = flat_dist(cur, mpos)
        if dm >= AVOID_DIST then return dest end
        local away = Vector3.new(cur.X - mpos.X, 0, cur.Z - mpos.Z)
        if away.Magnitude < 0.1 then away = Vector3.new(1, 0, 0) end
        away = away.Unit
        local want = Vector3.new(dest.X - cur.X, 0, dest.Z - cur.Z)
        local mag = want.Magnitude
        if mag < 0.1 then return dest end
        local weight = 1 + (1 - dm / AVOID_DIST) * 2
        local blend = want.Unit + away * weight
        if blend.Magnitude < 0.1 then blend = away else blend = blend.Unit end
        local np = cur + blend * mag
        return Vector3.new(np.X, dest.Y, np.Z)
    end

    local function touch_targets(coin)
        local list = {}
        local seen = {}
        local function add(p)
            if p and not seen[p] and p:IsA("BasePart") and p:FindFirstChildOfClass("TouchTransmitter") then
                seen[p] = true
                list[#list + 1] = p
            end
        end
        add(coin)
        for _, v in ipairs(coin:GetChildren()) do add(v) end
        local par = coin.Parent
        if par then
            if par:IsA("BasePart") then add(par) end
            for _, v in ipairs(par:GetChildren()) do add(v) end
        end
        if #list == 0 then list[1] = coin end
        return list
    end

    local function fire_touch(coin)
        if type(firetouchinterest) ~= "function" then return end
        if not coin or not coin.Parent then return end
        local now = os.clock()
        if now - last_touch < 0.05 then return end
        last_touch = now
        local hrp = farm_hrp()
        if not hrp then return end
        for _, p in ipairs(touch_targets(coin)) do
            pcall(firetouchinterest, hrp, p, 0)
            pcall(firetouchinterest, hrp, p, 1)
        end
    end

    local function farm_move(hrp, dest, dt)
        local dir = dest - hrp.Position
        local dist = dir.Magnitude
        local np = dest
        if dist > 0.1 then
            np = hrp.Position + dir.Unit * math.min(FARM_SPEED * dt, dist)
        end
        local cf = CFrame.new(np)
        if farm_mode == "Down" then
            cf = cf * CFrame.Angles(-math.pi * 0.5, 0, 0)
            was_down = true
        end
        pcall(function()
            hrp.CFrame = cf
            hrp.AssemblyLinearVelocity = Vector3.zero
            hrp.AssemblyAngularVelocity = Vector3.zero
        end)
    end

    local function farm_step(_, dt)
        if not autofarm_on then return end
        if not can_farm() then
            farm_target = nil
            was_down = false
            set_farm_noclip(false)
            return
        end
        local hrp = farm_hrp()
        if not hrp then return end

        local list = {}
        for _, v in ipairs(CollectionService:GetTagged("CoinVisual")) do
            if v and v.Parent and v:IsA("BasePart") then
                if not v:GetAttribute("Collected") and not v:GetAttribute("Delete") then
                    list[#list + 1] = v
                end
            end
        end

        local function finish()
            farm_target = nil
            farm_release()
            if not coins_done then
                coins_done = true
                if autoreset_on then
                    local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
                    if hum then
                        pcall(function() hum.Health = 0 end)
                    end
                end
            end
        end

        if saw_coins and coin_bags_full() then
            finish()
            return
        end

        if #list > 0 then
            saw_coins = true
            if coins_done then coins_done = false end

            local mhrp = avoid_murder and murderer_hrp() or nil
            local mpos = mhrp and mhrp.Position or nil

            if not coin_ok_now(farm_target, mpos) then
                farm_target = pick_coin(hrp.Position, list, mpos)
            end

            if farm_target then
                set_farm_noclip(true)
                local cpos = farm_target.Position
                down_ref_y = cpos.Y
                local dest = cpos

                if farm_mode == "Down" then
                    local xz = flat_dist(hrp.Position, cpos)
                    local safe_to_rise = (not mpos) or flat_dist(hrp.Position, mpos) > RISE_SAFE_DIST
                    if xz <= DOWN_RISE_XZ and safe_to_rise then
                        dest = cpos
                        fire_touch(farm_target)
                    else
                        dest = Vector3.new(cpos.X, cpos.Y - DOWN_DEPTH, cpos.Z)
                    end
                elseif (cpos - hrp.Position).Magnitude <= 6 then
                    fire_touch(farm_target)
                end

                dest = avoid_steer(hrp.Position, dest, mpos)
                farm_move(hrp, dest, dt)
            elseif mpos then
                set_farm_noclip(true)
                local away = Vector3.new(hrp.Position.X - mpos.X, 0, hrp.Position.Z - mpos.Z)
                if away.Magnitude < 0.1 then away = Vector3.new(1, 0, 0) end
                away = away.Unit
                local y = hrp.Position.Y
                if farm_mode == "Down" and down_ref_y then
                    y = down_ref_y - DOWN_DEPTH
                end
                farm_move(hrp, hrp.Position + away * 40 + Vector3.new(0, y - hrp.Position.Y, 0), dt)
            end
        else
            farm_target = nil
            farm_release()
            if saw_coins and not coins_done then
                finish()
            end
        end
    end

    local function setAutofarm(v)
        autofarm_on = v and true or false
        reset_farm_progress()
        if autofarm_on then
            if not farm_conn then
                farm_conn = RunSvc.Stepped:Connect(farm_step)
            end
        else
            if farm_conn then
                pcall(function() farm_conn:Disconnect() end)
                farm_conn = nil
            end
            farm_release()
        end
    end

    FarmMain:Toggle({
        Title = "Autofarm",
        Value = false,
        Callback = function(v)
            setAutofarm(v)
            notify("Autofarm", autofarm_on and "Autofarm ON" or "Autofarm OFF")
        end,
    })

    FarmMain:Dropdown({
        Title = "Farm Type",
        Values = { "Basic", "Down" },
        Callback = function(v)
            local nv = type(v) == "table" and (v.Title or v[1] or v) or v
            if nv ~= "Basic" and nv ~= "Down" then nv = "Basic" end
            if nv == farm_mode then return end
            farm_mode = nv
            farm_target = nil
            if farm_mode == "Basic" and was_down then
                was_down = false
                return_to_surface()
            end
        end,
    })

    FarmMain:Slider({
        Title = "Farm Speed",
        Step = 1,
        Value = { Min = 22, Max = 30, Default = 23 },
        Callback = function(v)
            FARM_SPEED = v
        end,
    })

    FarmMain:Toggle({
        Title = "Avoid Murder",
        Value = false,
        Callback = function(v)
            avoid_murder = v and true or false
            farm_target = nil
            notify("Autofarm", avoid_murder and "Avoid Murder ON" or "Avoid Murder OFF")
        end,
    })

    FarmMain:Toggle({
        Title = "Auto Reset Full Bag",
        Value = false,
        Callback = function(v)
            autoreset_on = v and true or false
            notify("Autofarm", autoreset_on and "Auto Reset ON" or "Auto Reset OFF")
        end,
    })
end)

pcall(function()
    if Window.SelectTab and MainTab then
        Window:SelectTab(MainTab)
    elseif Window.SelectTab then
        Window:SelectTab(1)
    end
end)

warn("[KvantScript] UI ready")

pcall(function()
    local wallhop_on = false
    local hop_params = RaycastParams.new()
    hop_params.FilterType = Enum.RaycastFilterType.Exclude
    hop_params.IgnoreWater = true
    local hop_ang = { 0, 0.45, -0.45, 0.9, -0.9, 1.4, -1.4, 2, -2, 2.6, -2.6, 3.14 }
    local hop_scan_t = 0

    local function hop_flat_unit(v)
        local f = Vector3.new(v.X, 0, v.Z)
        if f.Magnitude > 0 then return f.Unit end
        return Vector3.new(0, 0, 0)
    end

    local function hop_wall(hrp, hum)
        local cam = Workspace.CurrentCamera
        local base = hop_flat_unit(hum.MoveDirection)
        if base.Magnitude < 0.01 then
            base = cam and hop_flat_unit(cam.CFrame.LookVector) or Vector3.new(0, 0, 0)
        end
        if base.Magnitude < 0.01 then return nil end
        local ch = LocalPlayer.Character
        hop_params.FilterDescendantsInstances = ch and { ch } or {}
        local pos = hrp.Position
        for i = 1, #hop_ang do
            local c, s = math.cos(hop_ang[i]), math.sin(hop_ang[i])
            local dir = Vector3.new(base.X * c + base.Z * s, 0, base.Z * c - base.X * s) * 3
            local hit = Workspace:Raycast(pos, dir, hop_params)
            if not hit then
                hit = Workspace:Raycast(pos - Vector3.new(0, 2, 0), dir, hop_params)
            end
            if hit and math.abs(hit.Normal.Y) < 0.5 then
                return hit
            end
        end
        return nil
    end

    UserInputService.JumpRequest:Connect(function()
        if not wallhop_on then return end
        if InfJump then return end
        local ch = LocalPlayer.Character
        local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
        local hum = ch and ch:FindFirstChildOfClass("Humanoid")
        if not hrp or not hum or hum.Health <= 0 then return end
        if hum.FloorMaterial ~= Enum.Material.Air then return end
        local now = os.clock()
        if now - hop_scan_t < 0.1 then return end
        hop_scan_t = now
        local wall = hop_wall(hrp, hum)
        if not wall then return end
        local n = hop_flat_unit(wall.Normal)
        hum:ChangeState(Enum.HumanoidStateType.Jumping)
        local v = hrp.AssemblyLinearVelocity
        hrp.AssemblyLinearVelocity = Vector3.new(v.X + n.X * 3, v.Y, v.Z + n.Z * 3)
    end)

    getgenv().PH_SetWallhop = function(v)
        wallhop_on = v and true or false
    end
end)

pcall(function()
    local aura_on = false
    local aura_distance = 30
    local am_murderer_ka = false
    local aura_round_mod = nil
    local last_kill_aura = 0

    local function ka_refresh_murderer()
        local ok, result = pcall(function()
            local modules = ReplicatedStorage:FindFirstChild("Modules")
            if not modules then return false end
            local mod = modules:FindFirstChild("CurrentRoundClient")
            if not mod then return false end
            if not aura_round_mod then
                local rok, rm = pcall(require, mod)
                if not rok or type(rm) ~= "table" then return false end
                aura_round_mod = rm
            end
            local data = aura_round_mod.PlayerData
            if type(data) ~= "table" then return false end
            local me = data[LocalPlayer.Name]
            return me ~= nil and me.Role == "Murderer" and not me.Dead
        end)
        am_murderer_ka = ok and result == true
    end

    local function ka_get_knife()
        local char = LocalPlayer.Character
        if char then
            local equipped = char:FindFirstChild("Knife")
            if equipped then return equipped, true end
        end
        local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
        if backpack then
            local stored = backpack:FindFirstChild("Knife")
            if stored then return stored, false end
        end
        return nil, false
    end

    local function ka_ensure_knife()
        local knife, equipped = ka_get_knife()
        if not knife then return nil end
        if not equipped then
            local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
            if hum then
                pcall(function() hum:EquipTool(knife) end)
            end
            return nil
        end
        return knife
    end

    local function ka_knife_stab(knife)
        local events = knife:FindFirstChild("Events")
        local stabbed = events and events:FindFirstChild("KnifeStabbed")
        if stabbed then
            pcall(function() stabbed:FireServer() end)
        end
    end

    local function ka_knife_touch(knife, part)
        local events = knife:FindFirstChild("Events")
        local touched = events and events:FindFirstChild("HandleTouched")
        if touched then
            pcall(function() touched:FireServer(part) end)
        end
    end

    task.spawn(function()
        while true do
            task.wait(0.3)
            if aura_on then
                pcall(ka_refresh_murderer)
            end
        end
    end)

    task.spawn(function()
        while true do
            task.wait()
            if aura_on and am_murderer_ka then
                local knife = ka_ensure_knife()
                if knife and (os.clock() - last_kill_aura) >= 0.05 then
                    local char = LocalPlayer.Character
                    local my_part = char and char:FindFirstChild("HumanoidRootPart")
                    local victims = {}
                    local victim_count = 0
                    for _, plr in ipairs(Players:GetPlayers()) do
                        if plr ~= LocalPlayer then
                            local target_char = plr.Character
                            if target_char then
                                local hum = target_char:FindFirstChildOfClass("Humanoid")
                                if hum and hum.Health > 0 then
                                    local part = target_char:FindFirstChild("HumanoidRootPart") or target_char:FindFirstChild("Head")
                                    if part and my_part then
                                        local dist = (part.Position - my_part.Position).Magnitude
                                        if dist <= aura_distance then
                                            victim_count = victim_count + 1
                                            victims[victim_count] = part
                                        end
                                    end
                                end
                            end
                        end
                    end
                    if victim_count > 0 then
                        ka_knife_stab(knife)
                        for i = 1, victim_count do
                            ka_knife_touch(knife, victims[i])
                        end
                        last_kill_aura = os.clock()
                    end
                end
            end
        end
    end)

    getgenv().PH_SetKillAura = function(v)
        aura_on = v and true or false
        if aura_on then
            pcall(ka_refresh_murderer)
        end
    end
    getgenv().PH_SetKillAuraDistance = function(v)
        aura_distance = tonumber(v) or aura_distance
    end
end)

pcall(function()
    local TweenService = game:GetService("TweenService")
    local Debris = game:GetService("Debris")

    local lc_on = false
    local lc_col = Color3.new(1, 1, 1)
    local lc_tr = 1
    local lc_dur = 0.82
    local lc_con = nil
    local lc_char_con = nil

    local function lc_hit(char, root)
        local prm = RaycastParams.new()
        prm.FilterType = Enum.RaycastFilterType.Exclude
        prm.FilterDescendantsInstances = { char }
        prm.IgnoreWater = true
        local sum = Vector3.new(0, 0, 0)
        local nor = Vector3.new(0, 0, 0)
        local cnt = 0
        for _, name in ipairs({ "LeftFoot", "RightFoot", "Left Leg", "Right Leg" }) do
            local foot = char:FindFirstChild(name)
            if foot and foot:IsA("BasePart") then
                local hit = Workspace:Raycast(foot.Position + Vector3.new(0, 0.35, 0), Vector3.new(0, -7, 0), prm)
                if hit then
                    sum = sum + hit.Position
                    nor = nor + hit.Normal
                    cnt = cnt + 1
                end
            end
        end
        if cnt > 0 then
            return sum / cnt, nor.Unit
        end
        local hit = Workspace:Raycast(root.Position + Vector3.new(0, 1, 0), Vector3.new(0, -16, 0), prm)
        if hit then
            return hit.Position, hit.Normal
        end
        return nil, nil
    end

    local function lc_make(p, n)
        if not p or not n then return end
        local ref = math.abs(n.Y) > 0.98 and Vector3.new(1, 0, 0) or Vector3.new(0, 1, 0)
        local right = n:Cross(ref)
        if right.Magnitude < 0.001 then
            right = Vector3.new(1, 0, 0)
        else
            right = right.Unit
        end
        local front = right:Cross(n).Unit
        local part = Instance.new("Part")
        part.Name = "LandingCircle"
        part.Anchored = true
        part.CanCollide = false
        part.CanQuery = false
        part.CanTouch = false
        part.CastShadow = false
        part.Transparency = 1
        part.Size = Vector3.new(0.3, 0.01, 0.3)
        part.CFrame = CFrame.fromMatrix(p + n * 0.012, right, n, front)
        part.Parent = Workspace
        local sg = Instance.new("SurfaceGui")
        sg.Face = Enum.NormalId.Top
        sg.AlwaysOnTop = true
        sg.LightInfluence = 0
        sg.ZOffset = 4
        sg.CanvasSize = Vector2.new(1024, 1024)
        sg.Parent = part
        local img = Instance.new("ImageLabel")
        img.BackgroundTransparency = 1
        img.Size = UDim2.fromScale(1, 1)
        img.Image = "rbxassetid://7185003058"
        img.ImageColor3 = lc_col
        img.ImageTransparency = 1 - lc_tr
        img.ScaleType = Enum.ScaleType.Stretch
        img.Parent = sg
        local info = TweenInfo.new(lc_dur, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
        TweenService:Create(part, info, { Size = Vector3.new(6.4, 0.01, 6.4) }):Play()
        TweenService:Create(img, info, { ImageTransparency = 1 }):Play()
        Debris:AddItem(part, lc_dur + 0.2)
    end

    local function lc_bind()
        if lc_con then
            pcall(function() lc_con:Disconnect() end)
            lc_con = nil
        end
        if not lc_on then return end
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if not hum or not root then return end
        local air = false
        lc_con = hum.StateChanged:Connect(function(_, state)
            if state == Enum.HumanoidStateType.Jumping or state == Enum.HumanoidStateType.Freefall then
                air = true
                return
            end
            if state == Enum.HumanoidStateType.Landed and air and lc_on then
                air = false
                local p, n = lc_hit(char, root)
                if p and n then
                    lc_make(p, n)
                end
            end
        end)
    end

    if lc_char_con then
        pcall(function() lc_char_con:Disconnect() end)
    end
    lc_char_con = LocalPlayer.CharacterAdded:Connect(function()
        task.wait(0.3)
        if lc_on then
            lc_bind()
        end
    end)

    getgenv().PH_SetLandingCircle = function(v)
        lc_on = v and true or false
        if lc_on then
            lc_bind()
        elseif lc_con then
            pcall(function() lc_con:Disconnect() end)
            lc_con = nil
        end
    end
    getgenv().PH_SetLandingCircleColor = function(c)
        if typeof(c) == "Color3" then
            lc_col = c
        end
    end
    getgenv().PH_SetLandingCircleTr = function(v)
        lc_tr = math.clamp(tonumber(v) or lc_tr, 0, 1)
    end
    getgenv().PH_SetLandingCircleDur = function(v)
        lc_dur = math.clamp(tonumber(v) or lc_dur, 0.1, 3)
    end
end)

pcall(function()
    local TweenService = game:GetService("TweenService")
    local Debris = game:GetService("Debris")
    local UIS = game:GetService("UserInputService")

    local sheriff_on = false
    local bullet_on = false
    local sheriff_color = Color3.fromRGB(133, 220, 255)
    local sheriff_duration = 1
    local bullet_color = Color3.fromRGB(255, 200, 50)
    local bullet_duration = 1.2
    local bullet_thickness = 2.5
    local gun_fired_conn = nil
    local fade_tween = TweenInfo.new(0.25, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)

    getgenv().SHERIFF_TRACER_ENABLED = false
    getgenv().SHERIFF_TRACER_COLOR = sheriff_color
    getgenv().SHERIFF_TRACER_DURATION = sheriff_duration

    local function get_weapon_service()
        local ok, m = pcall(function()
            local cs = ReplicatedStorage:FindFirstChild("ClientServices")
            local ws = cs and cs:FindFirstChild("WeaponService")
            if not ws then return nil end
            if ws:IsA("ModuleScript") then
                return require(ws)
            end
            return ws
        end)
        if ok then return m end
        return nil
    end

    local function is_local_gun_user(gun)
        local char = LocalPlayer.Character
        if not char then return false end
        if typeof(gun) == "Instance" then
            local ok, mine = pcall(function()
                return gun:IsDescendantOf(char)
            end)
            if ok and mine then return true end
        end
        if char:FindFirstChild("Gun") then return true end
        local bp = LocalPlayer:FindFirstChildOfClass("Backpack")
        if bp and bp:FindFirstChild("Gun") then return true end
        return false
    end

    local function make_point(position, lifetime)
        local part = Instance.new("Part")
        part.Transparency = 1
        part.Anchored = true
        part.CanCollide = false
        part.CanQuery = false
        part.Size = Vector3.new(0.2, 0.2, 0.2)
        part.CFrame = CFrame.new(position)
        Instance.new("Attachment", part)
        Debris:AddItem(part, lifetime)
        part.Parent = Workspace
        return part
    end

    local function to_position(value)
        if typeof(value) == "Vector3" then
            return value
        elseif typeof(value) == "CFrame" then
            return value.Position
        elseif typeof(value) == "Instance" then
            if value:IsA("Attachment") then
                return value.WorldPosition
            elseif value:IsA("BasePart") then
                return value.Position
            end
        end
        return nil
    end

    local function gun_muzzle(gun)
        if typeof(gun) ~= "Instance" then return nil end
        local att = gun:FindFirstChild("GunRaycastAttachment", true)
        if att and att:IsA("Attachment") then
            return att.WorldPosition
        end
        local handle = gun:FindFirstChild("Handle") or gun:FindFirstChildWhichIsA("BasePart", true)
        if handle then
            return handle.Position
        end
        return nil
    end

    local function aim_end_from_camera()
        local cam = Workspace.CurrentCamera
        if not cam then
            return Vector3.new(0, 0, 0)
        end
        local mp = UIS:GetMouseLocation()
        local ray = cam:ViewportPointToRay(mp.X, mp.Y)
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        local char = LocalPlayer.Character
        params.FilterDescendantsInstances = char and { char } or {}
        params.IgnoreWater = true
        local hit = Workspace:Raycast(ray.Origin, ray.Direction * 500, params)
        if hit then
            return hit.Position
        end
        return ray.Origin + ray.Direction * 400
    end

    local function resolve_points(gun, a, b)
        local sp = to_position(a)
        local ep = to_position(b)
        if not sp then
            sp = gun_muzzle(gun)
        end
        if not sp then
            local char = LocalPlayer.Character
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            if hrp then
                sp = hrp.Position + Vector3.new(0, 1.5, 0)
            end
        end
        if not ep and sp then
            ep = aim_end_from_camera()
        end
        return sp, ep
    end

    local function create_beam(start_position, end_position, color, duration, width)
        if not start_position or not end_position then return end
        if (start_position - end_position).Magnitude < 0.5 then return end

        local start_part = make_point(start_position, duration + 0.6)
        local end_part = make_point(end_position, duration + 0.6)
        local w = width or 0.25

        local beam = Instance.new("Beam")
        beam.FaceCamera = true
        beam.TextureSpeed = 1.5
        beam.TextureLength = 2
        beam.Width0 = w
        beam.Width1 = w
        beam.LightEmission = 3
        beam.LightInfluence = 0
        beam.Brightness = 2.5
        beam.Texture = "rbxassetid://12781800668"
        beam.Color = ColorSequence.new(color)
        beam.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.05),
            NumberSequenceKeypoint.new(1, 0.15),
        })
        beam.Attachment0 = start_part:FindFirstChildOfClass("Attachment")
        beam.Attachment1 = end_part:FindFirstChildOfClass("Attachment")
        beam.Parent = start_part

        task.delay(duration, function()
            if beam.Parent then
                TweenService:Create(beam, fade_tween, { Width0 = 0, Width1 = 0 }):Play()
            end
        end)
    end

    local function on_gun_fired(gun, a, b)
        if not bullet_on then return end
        if not is_local_gun_user(gun) then return end
        local sp, ep = resolve_points(gun, a, b)
        create_beam(sp, ep, bullet_color, bullet_duration, bullet_thickness)
    end

    local function connect_gun_fired()
        local m = get_weapon_service()
        local ev = nil
        if type(m) == "table" then
            ev = m.GunFired
        elseif typeof(m) == "Instance" then
            ev = m:FindFirstChild("GunFired")
        end
        if typeof(ev) ~= "Instance" then
            local cs = ReplicatedStorage:FindFirstChild("ClientServices")
            local ws = cs and cs:FindFirstChild("WeaponService")
            ev = ws and ws:FindFirstChild("GunFired")
        end
        if typeof(ev) ~= "Instance" then return end
        if gun_fired_conn then
            local okc, connected = pcall(function() return gun_fired_conn.Connected end)
            if okc and connected then return end
            pcall(function() gun_fired_conn:Disconnect() end)
            gun_fired_conn = nil
        end
        gun_fired_conn = ev.OnClientEvent:Connect(function(gun, a, b)
            task.spawn(on_gun_fired, gun, a, b)
        end)
    end

    local function ensure_conn()
        if bullet_on then
            pcall(connect_gun_fired)
        end
    end

    task.spawn(function()
        while true do
            if bullet_on then
                pcall(connect_gun_fired)
            end
            task.wait(1)
        end
    end)

    getgenv().PH_SetSheriffTracer = function(v)
        sheriff_on = v and true or false
        getgenv().SHERIFF_TRACER_ENABLED = sheriff_on
        ensure_conn()
    end
    getgenv().PH_SetSheriffTracerColor = function(c)
        if typeof(c) == "Color3" then
            sheriff_color = c
            getgenv().SHERIFF_TRACER_COLOR = c
        end
    end
    getgenv().PH_SetSheriffTracerDuration = function(v)
        local n = tonumber(v)
        if n then
            sheriff_duration = n
            getgenv().SHERIFF_TRACER_DURATION = n
        end
    end

    getgenv().PH_SetBulletTracer = function(v)
        bullet_on = v and true or false
        ensure_conn()
    end
    getgenv().PH_SetBulletTracerColor = function(c)
        if typeof(c) == "Color3" then
            bullet_color = c
        end
    end
    getgenv().PH_SetBulletTracerThickness = function(v)
        local n = tonumber(v)
        if n then
            bullet_thickness = math.clamp(n, 0.5, 6)
        end
    end
    getgenv().PH_SetBulletTracerDuration = function(v)
        local n = tonumber(v)
        if n then
            bullet_duration = n
        end
    end
end)

pcall(function()
    local korblox_on = false
    local headless_on = false
    local korblox_backup = {}
    local head_backup = {}
    local custom_id = ""
    local custom_on = false
    local custom_parts = {}

    local function restore_korblox()
        local c = LocalPlayer.Character
        if not c then return end
        local ru = c:FindFirstChild("RightUpperLeg")
        local rl = c:FindFirstChild("RightLowerLeg")
        local rf = c:FindFirstChild("RightFoot")
        if ru and korblox_backup.RU then
            pcall(function()
                if ru:IsA("MeshPart") then
                    ru.TextureID = korblox_backup.RU.TextureID or ""
                    ru.MeshId = korblox_backup.RU.MeshId or ""
                end
            end)
        end
        if rl and korblox_backup.RL then
            pcall(function()
                if rl:IsA("MeshPart") then
                    rl.MeshId = korblox_backup.RL.MeshId or ""
                end
                rl.Transparency = korblox_backup.RL.Transparency or 0
            end)
        end
        if rf and korblox_backup.RF then
            pcall(function()
                if rf:IsA("MeshPart") then
                    rf.MeshId = korblox_backup.RF.MeshId or ""
                end
                rf.Transparency = korblox_backup.RF.Transparency or 0
            end)
        end
        korblox_backup = {}
    end

    local function restore_headless()
        local c = LocalPlayer.Character
        if not c then return end
        local head = c:FindFirstChild("Head")
        if head and head_backup.Head ~= nil then
            pcall(function()
                head.Transparency = head_backup.Head
                if head:IsA("MeshPart") then
                    if head_backup.MeshId then head.MeshId = head_backup.MeshId end
                    if head_backup.TextureID then head.TextureID = head_backup.TextureID end
                end
            end)
        end
        for _, v in ipairs(head_backup.Children or {}) do
            if v.Obj and v.Obj.Parent then
                pcall(function() v.Obj.Transparency = v.Val end)
            end
        end
        head_backup = {}
    end

    local function apply_korblox()
        if not korblox_on then return end
        local c = LocalPlayer.Character
        if not c then return end
        local ru = c:FindFirstChild("RightUpperLeg")
        local rl = c:FindFirstChild("RightLowerLeg")
        local rf = c:FindFirstChild("RightFoot")
        if not ru then return end
        korblox_backup = {}
        if ru:IsA("MeshPart") then
            korblox_backup.RU = { MeshId = ru.MeshId, TextureID = ru.TextureID }
            pcall(function()
                ru.MeshId = "rbxassetid://902942096"
                ru.TextureID = "rbxassetid://902843398"
            end)
        end
        if rl and rl:IsA("MeshPart") then
            korblox_backup.RL = { MeshId = rl.MeshId, Transparency = rl.Transparency }
            pcall(function()
                rl.MeshId = "rbxassetid://902942093"
                rl.Transparency = 1
            end)
        end
        if rf and rf:IsA("MeshPart") then
            korblox_backup.RF = { MeshId = rf.MeshId, Transparency = rf.Transparency }
            pcall(function()
                rf.MeshId = "rbxassetid://902942089"
                rf.Transparency = 1
            end)
        end
    end

    local function apply_headless()
        if not headless_on then return end
        restore_headless()
        local c = LocalPlayer.Character
        if not c then return end
        local head = c:FindFirstChild("Head")
        if not head then return end
        head_backup.Head = head.Transparency
        if head:IsA("MeshPart") then
            head_backup.MeshId = head.MeshId
            head_backup.TextureID = head.TextureID
        end
        head_backup.Children = {}
        pcall(function()
            if head:IsA("MeshPart") then
                head.MeshId = "rbxassetid://6686307858"
                head.TextureID = "rbxassetid://6686307858"
            end
            head.Transparency = 1
        end)
        for _, child in ipairs(head:GetDescendants()) do
            if child:IsA("BasePart") or child:IsA("Decal") or child:IsA("MeshPart") or child:IsA("SpecialMesh") then
                local okT, original = pcall(function() return child.Transparency end)
                if okT then
                    head_backup.Children[#head_backup.Children + 1] = { Obj = child, Val = original }
                    pcall(function() child.Transparency = 1 end)
                end
            end
        end
        local face = head:FindFirstChild("face") or head:FindFirstChild("Face")
        if face then
            pcall(function() face.Transparency = 1 end)
        end
    end

    local function parse_asset_id(text)
        if type(text) ~= "string" then text = tostring(text or "") end
        local n = string.match(text, "(%d+)")
        return n and tonumber(n) or nil
    end

    local function clear_custom()
        for _, entry in ipairs(custom_parts) do
            if entry.Obj and entry.Obj.Parent then
                pcall(function()
                    if entry.Kind == "mesh" and entry.Obj:IsA("MeshPart") then
                        if entry.MeshId then entry.Obj.MeshId = entry.MeshId end
                        if entry.TextureID then entry.Obj.TextureID = entry.TextureID end
                        if entry.Transparency ~= nil then entry.Obj.Transparency = entry.Transparency end
                    elseif entry.Kind == "special" and entry.Obj.Parent then
                        entry.Obj:Destroy()
                    elseif entry.Kind == "hide" then
                        entry.Obj.Transparency = entry.Transparency or 0
                    end
                end)
            end
        end
        custom_parts = {}
        custom_on = false
    end

    local function apply_custom(id)
        clear_custom()
        id = id or parse_asset_id(custom_id)
        if not id then
            notify("Player", "Invalid model asset id")
            return
        end
        local c = LocalPlayer.Character
        if not c then return end
        local meshId = "rbxassetid://" .. tostring(id)


        local loaded = nil
        pcall(function()
            if game.GetObjects then
                local objs = game:GetObjects(meshId)
                if objs and objs[1] then loaded = objs[1] end
            end
        end)
        pcall(function()
            if not loaded and game:GetService("InsertService") then
                local ok, model = pcall(function()
                    return game:GetService("InsertService"):LoadAsset(id)
                end)
                if ok and model then
                    loaded = model:IsA("Model") and (model:GetChildren()[1] or model) or model
                end
            end
        end)

        if loaded then

            local map = {
                Head = true, Torso = true, HumanoidRootPart = true,
                LeftUpperArm = true, RightUpperArm = true,
                LeftLowerArm = true, RightLowerArm = true,
                LeftHand = true, RightHand = true,
                LeftUpperLeg = true, RightUpperLeg = true,
                LeftLowerLeg = true, RightLowerLeg = true,
                LeftFoot = true, RightFoot = true,
                ["Left Arm"] = true, ["Right Arm"] = true,
                ["Left Leg"] = true, ["Right Leg"] = true,
            }
            local applied = 0
            for _, src in ipairs(loaded:GetDescendants()) do
                if src:IsA("MeshPart") and map[src.Name] then
                    local dst = c:FindFirstChild(src.Name)
                    if dst and dst:IsA("MeshPart") then
                        custom_parts[#custom_parts + 1] = {
                            Kind = "mesh",
                            Obj = dst,
                            MeshId = dst.MeshId,
                            TextureID = dst.TextureID,
                            Transparency = dst.Transparency,
                        }
                        pcall(function()
                            dst.MeshId = src.MeshId
                            dst.TextureID = src.TextureID
                        end)
                        applied = applied + 1
                    end
                end
            end
            pcall(function()
                if loaded.Parent then loaded:Destroy() end
            end)
            if applied > 0 then
                custom_on = true
                notify("Player", "Custom model applied (" .. applied .. " parts)")
                return
            end
        end



        local head = c:FindFirstChild("Head")
        if head and head:IsA("MeshPart") then
            custom_parts[#custom_parts + 1] = {
                Kind = "mesh",
                Obj = head,
                MeshId = head.MeshId,
                TextureID = head.TextureID,
                Transparency = head.Transparency,
            }
            pcall(function()
                head.MeshId = meshId
            end)
            custom_on = true
            notify("Player", "Applied mesh id to Head (fallback)")
            return
        end
        notify("Player", "Could not apply model id")
    end

    local function reapply_all()
        task.wait(0.4)
        if korblox_on then apply_korblox() end
        if headless_on then apply_headless() end
        if custom_on and custom_id ~= "" then
            apply_custom(parse_asset_id(custom_id))
        end
    end

    LocalPlayer.CharacterAdded:Connect(function()
        task.spawn(reapply_all)
    end)

    getgenv().PH_SetKorblox = function(v)
        korblox_on = v and true or false
        if korblox_on then
            apply_korblox()
        else
            restore_korblox()
        end
    end
    getgenv().PH_SetHeadless = function(v)
        headless_on = v and true or false
        if headless_on then
            apply_headless()
        else
            restore_headless()
        end
    end
    getgenv().PH_SetCustomModelId = function(text)
        custom_id = tostring(text or "")
    end
    getgenv().PH_ApplyCustomModel = function()
        local id = parse_asset_id(custom_id)
        if not id then
            notify("Player", "Enter a valid asset id first")
            return
        end
        apply_custom(id)
    end
    getgenv().PH_ClearCustomModel = function()
        clear_custom()
    end
end)

pcall(function()
    local RunService = game:GetService("RunService")
    local render_stepped = RunService.RenderStepped
    local render_stepped_wait = render_stepped.Wait

    local fake_pos_active = false
    local range_mul = 9
    local anti_aim = {}
    local local_parts = {}
    local local_client_position = CFrame.new()
    local local_server_position = CFrame.new()
    local local_fps = 60
    local fake_position_sitting = false
    local tp_settle_until = 0
    local pending_teleport = nil
    local hb_conn = nil
    local ltm_conn = nil
    local sit_conn = nil
    local char_conn = nil
    local ltm_parts = {}
    local ltm_char = nil
    local ltm_valid = false
    local hrp_protected = {}
    local hooked_metatables = {}

    getgenv().FAKE_POS_ACTIVE = false
    getgenv().FAKE_POS_MULTI_AXIS = { X = true, Y = true, Z = true }
    getgenv().FAKE_POS_RANGE_X = 9e9
    getgenv().FAKE_POS_RANGE_Y = 9e9
    getgenv().FAKE_POS_RANGE_Z = 9e9

    local function remove_from(tbl, index)
        local length = #tbl
        for i = index, length - 1 do
            tbl[i] = tbl[i + 1]
        end
        tbl[length] = nil
    end

    local function ltm_parts_for(character)
        if ltm_char ~= character then
            ltm_char = character
            ltm_valid = false
            table.clear(ltm_parts)
        end
        if not ltm_valid and character then
            table.clear(ltm_parts)
            local n = 0
            for _, part in ipairs(character:GetDescendants()) do
                if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
                    n = n + 1
                    ltm_parts[n] = part
                end
            end
            ltm_valid = true
        end
        return ltm_parts
    end

    local function set_local_body_transparency(value)
        local character = LocalPlayer.Character
        if not character then return end
        local parts = ltm_parts_for(character)
        local target = value and 0.6 or 0
        for i = 1, #parts do
            local part = parts[i]
            if part and part.Parent then
                pcall(function()
                    part.LocalTransparencyModifier = target
                end)
            end
        end
    end

    local function set_world_limits(disable)
        pcall(function()
            if disable then
                if sethiddenproperty and gethiddenproperty then
                    getgenv()._PH_FallenOld = gethiddenproperty(Workspace, "FallenPartsDestroyHeight")
                    sethiddenproperty(Workspace, "FallenPartsDestroyHeight", -9e9)
                end
            else
                if sethiddenproperty then
                    sethiddenproperty(Workspace, "FallenPartsDestroyHeight", getgenv()._PH_FallenOld or -500)
                end
            end
        end)
    end

    local function apply_hrp_fix(hrp)
        if not hrp or hrp_protected[hrp] then return end
        if type(getrawmetatable) ~= "function" or type(setrawmetatable) ~= "function" then
            return
        end
        local old = getrawmetatable(hrp)
        if not old then return end
        local old_index = old.__index
        local old_newindex = old.__newindex
        hrp_protected[hrp] = true
        hooked_metatables[hrp] = { mt = old, target = hrp }

        local wrap = (type(newcclosure) == "function") and newcclosure or function(f) return f end
        local has_check = type(checkcaller) == "function"

        local new = {
            __index = wrap(function(self, index)
                if has_check and not checkcaller() and self and index == "CFrame" and #anti_aim ~= 0 then
                    return local_client_position
                end
                return old_index(self, index)
            end),
            __newindex = wrap(function(self, index, value)
                if has_check and not checkcaller() and self then
                    if index == "Anchored" then
                        return
                    end
                    if (index == "CFrame" or index == "Position") and #anti_aim ~= 0 then
                        return
                    end
                end
                return old_newindex(self, index, value)
            end),
        }
        for k, v in pairs(old) do
            if new[k] == nil then
                new[k] = v
            end
        end
        pcall(function()
            setrawmetatable(hrp, new)
        end)
    end

    local function restore_hrp_hooks()
        for hrp, data in pairs(hooked_metatables) do
            pcall(function()
                setrawmetatable(data.target, data.mt)
            end)
        end
        table.clear(hooked_metatables)
        table.clear(hrp_protected)
    end

    local function do_fake_position(dt, hrp)
        if not fake_pos_active then return end
        if fake_position_sitting then return end
        if not hrp or not hrp.Parent then return end
        if dt and dt > 0.45 then return end

        pcall(function()
            if sethiddenproperty then
                sethiddenproperty(hrp, "NetworkIsSleeping", false)
            end
        end)

        pcall(function()
            if hrp.AssemblyLinearVelocity.Magnitude < 1 then
                hrp.AssemblyLinearVelocity = Vector3.new(0, 0.1, 0)
            end
        end)

        local axes = getgenv().FAKE_POS_MULTI_AXIS or { X = true, Y = true, Z = true }
        local rx = getgenv().FAKE_POS_RANGE_X or (range_mul * 1e9)
        local ry = getgenv().FAKE_POS_RANGE_Y or (range_mul * 1e9)
        local rz = getgenv().FAKE_POS_RANGE_Z or (range_mul * 1e9)
        local base = local_client_position.Position
        local x = axes.X and ((math.random() * 2 - 1) * rx) or base.X
        local y = axes.Y and (-(math.random()) * ry) or base.Y
        local z = axes.Z and ((math.random() * 2 - 1) * rz) or base.Z

        if pending_teleport then
            pcall(function()
                hrp.CFrame = pending_teleport
                hrp.AssemblyLinearVelocity = Vector3.zero
                hrp.AssemblyAngularVelocity = Vector3.zero
            end)
            local_client_position = pending_teleport
            pending_teleport = nil
        end

        local old = hrp.CFrame
        local fake_cf = CFrame.new(Vector3.new(x, y, z))
            * CFrame.Angles(
                math.rad(math.random(1, 359)),
                math.rad(math.random(1, 359)),
                math.rad(math.random(1, 359))
            )
        hrp.CFrame = fake_cf
        render_stepped_wait(render_stepped)
        hrp.CFrame = old
    end

    local function fake_position_stop_sitting(character)
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        if not humanoid then return end
        local_parts["Humanoid"] = humanoid
        fake_position_sitting = humanoid.Sit
        if sit_conn then
            pcall(function() sit_conn:Disconnect() end)
            sit_conn = nil
        end
        sit_conn = humanoid:GetPropertyChangedSignal("Sit"):Connect(function()
            fake_position_sitting = humanoid.Sit
        end)
    end

    local function init_character(character)
        if not character then return end
        ltm_valid = false
        local hrp = character:WaitForChild("HumanoidRootPart", 5)
        if not hrp then return end
        local_parts["HumanoidRootPart"] = hrp
        local humanoid = character:FindFirstChildOfClass("Humanoid")
        local_parts["Humanoid"] = humanoid
        local_client_position = hrp.CFrame
        apply_hrp_fix(hrp)
        if humanoid then
            fake_position_stop_sitting(character)
        end
        if fake_pos_active then
            set_local_body_transparency(true)
        end
    end

    local function start_heartbeat()
        if hb_conn then return end
        local last_fps = os.clock()
        hb_conn = RunService.Heartbeat:Connect(function(dt)
            local now = os.clock()
            local_fps = 1 / math.max(now - last_fps, 1 / 240)
            last_fps = now

            local hrp = local_parts["HumanoidRootPart"]
            if not hrp or not hrp.Parent then
                local char = LocalPlayer.Character
                hrp = char and char:FindFirstChild("HumanoidRootPart")
                if hrp then
                    local_parts["HumanoidRootPart"] = hrp
                    apply_hrp_fix(hrp)
                end
            end


            if hrp then
                local_client_position = hrp.CFrame
            end

            if hrp and os.clock() < tp_settle_until then
                pcall(function()
                    hrp.AssemblyLinearVelocity = Vector3.zero
                    hrp.AssemblyAngularVelocity = Vector3.zero
                end)
            end

            if fake_pos_active and hrp then
                for i = 1, #anti_aim do
                    local fn = anti_aim[i]
                    if fn then
                        task.spawn(fn, dt, hrp)
                    end
                end
            end

            if hrp then
                local_server_position = hrp.CFrame
            end
        end)

        ltm_conn = RunService.RenderStepped:Connect(function()
            if fake_pos_active then
                set_local_body_transparency(true)
            end
        end)

        pcall(function()
            RunService:BindToRenderStep("PH_FakePosCam", Enum.RenderPriority.Camera.Value - 1, function()
                if not fake_pos_active then return end
                local hrp = local_parts["HumanoidRootPart"]
                if not hrp or not local_client_position then return end
                local ok, pos = pcall(function()
                    return hrp.Position
                end)
                if ok and pos and (pos - local_client_position.Position).Magnitude > 500 then
                    pcall(function()
                        hrp.CFrame = local_client_position
                    end)
                end
            end)
        end)
    end

    local function stop_heartbeat()
        if hb_conn then
            pcall(function() hb_conn:Disconnect() end)
            hb_conn = nil
        end
        if ltm_conn then
            pcall(function() ltm_conn:Disconnect() end)
            ltm_conn = nil
        end
        pcall(function()
            RunService:UnbindFromRenderStep("PH_FakePosCam")
        end)
    end

    local function fake_position_enable(value)
        fake_pos_active = value and true or false
        getgenv().FAKE_POS_ACTIVE = fake_pos_active

        for i = #anti_aim, 1, -1 do
            if anti_aim[i] == do_fake_position then
                remove_from(anti_aim, i)
            end
        end

        set_local_body_transparency(fake_pos_active)

        if fake_pos_active then
            set_world_limits(true)
            anti_aim[#anti_aim + 1] = do_fake_position
            start_heartbeat()

            local hrp = local_parts["HumanoidRootPart"]
            if hrp then
                pcall(function()
                    if sethiddenproperty then
                        sethiddenproperty(hrp, "NetworkIsSleeping", false)
                    end

                    if hrp.AssemblyLinearVelocity.Magnitude < 1 then
                        hrp.AssemblyLinearVelocity = Vector3.new(0, 0.1, 0)
                    end
                end)
            end

            if LocalPlayer.Character then
                fake_position_stop_sitting(LocalPlayer.Character)
            end
        else
            set_world_limits(false)
            local hrp = local_parts["HumanoidRootPart"]
            if hrp and local_client_position then
                pcall(function()
                    if sethiddenproperty then
                        sethiddenproperty(hrp, "NetworkIsSleeping", false)
                    end
                    hrp.CFrame = local_client_position
                end)
            end
            set_local_body_transparency(false)

            if #anti_aim == 0 then
                stop_heartbeat()
            end
        end
    end

    if LocalPlayer.Character then
        task.spawn(function()
            init_character(LocalPlayer.Character)
        end)
    end
    char_conn = LocalPlayer.CharacterAdded:Connect(function(char)
        task.wait(0.5)
        init_character(char)
        if fake_pos_active then
            set_local_body_transparency(true)
        end
    end)

    getgenv().PH_SetInvisible = function(v)
        fake_position_enable(v and true or false)
    end

    getgenv().PH_SetInvisRange = function(v)
        local n = tonumber(v)
        if not n then return end
        range_mul = math.clamp(math.floor(n), 1, 9)
        getgenv().FAKE_POS_RANGE_X = range_mul * 1e9
        getgenv().FAKE_POS_RANGE_Y = range_mul * 1e9
        getgenv().FAKE_POS_RANGE_Z = range_mul * 1e9
    end
end)

pcall(function()
    local function my_hrp()
        local c = LocalPlayer.Character
        return c and c:FindFirstChild("HumanoidRootPart")
    end

    local function break_velocity()
        local hrp = my_hrp()
        if hrp then
            pcall(function()
                hrp.AssemblyLinearVelocity = Vector3.zero
                hrp.AssemblyAngularVelocity = Vector3.zero
            end)
        end
    end

    local function tp_root(cf)
        if type(getgenv().SHITARO_TELEPORT) == "function" then
            local ok = pcall(getgenv().SHITARO_TELEPORT, cf)
            if ok then return end
        end
        local hrp = my_hrp()
        if hrp then
            pcall(function()
                hrp.CFrame = cf
            end)
        end
        break_velocity()
    end

    local function stable_tp(cf)
        tp_root(cf)
        if getgenv().FAKE_POS_ACTIVE then return end
        task.spawn(function()
            local hrp = my_hrp()
            if not hrp then return end
            local t0 = os.clock()
            while os.clock() - t0 < 0.25 and hrp.Parent do
                break_velocity()
                task.wait()
            end
        end)
    end

    local function in_lobby(obj)
        local p = obj.Parent
        while p and p ~= Workspace do
            if p.Name == "RegularLobby" or p.Name == "Lobby" then
                return true
            end
            p = p.Parent
        end
        return false
    end

    local function teleport_to_map()
        local root = my_hrp()
        if not root then
            notify("Teleport", "No character")
            return
        end
        local spawnParts = {}
        for _, obj in ipairs(Workspace:GetDescendants()) do
            if (obj:IsA("SpawnLocation") or (obj:IsA("BasePart") and obj.Name == "Spawn")) and not in_lobby(obj) then
                spawnParts[#spawnParts + 1] = obj
            end
        end
        if #spawnParts > 0 then
            local rspawn = spawnParts[math.random(1, #spawnParts)]
            stable_tp(rspawn.CFrame + Vector3.new(0, 5, 0))
            notify("Teleport", "Teleported to map")
        else
            notify("Teleport", "No map spawn found")
        end
    end

    local function teleport_to_lobby()
        local root = my_hrp()
        if not root then
            notify("Teleport", "No character")
            return
        end
        local lobby = Workspace:FindFirstChild("RegularLobby") or Workspace:FindFirstChild("Lobby")
        if not lobby then
            notify("Teleport", "Lobby not found")
            return
        end
        local locs = {}
        for _, obj in ipairs(lobby:GetDescendants()) do
            if obj:IsA("SpawnLocation") or (obj:IsA("BasePart") and obj.Name == "Spawn") then
                locs[#locs + 1] = obj
            end
        end
        if #locs > 0 then
            local rspawn = locs[math.random(1, #locs)]
            stable_tp(rspawn.CFrame + Vector3.new(0, 3, 0))
            notify("Teleport", "Teleported to lobby")
        else
            local ok, pivot = pcall(function()
                return lobby:GetPivot()
            end)
            if ok and pivot then
                stable_tp(pivot + Vector3.new(0, 5, 0))
                notify("Teleport", "Teleported to lobby")
            else
                notify("Teleport", "No lobby spawn")
            end
        end
    end

    local tp_on = false
    local tp_tool = nil
    local tp_act_conn = nil
    local tp_add_conn = nil

    local function remove_tp_tool()
        if tp_act_conn then
            pcall(function() tp_act_conn:Disconnect() end)
            tp_act_conn = nil
        end
        if tp_tool then
            pcall(function() tp_tool:Destroy() end)
            tp_tool = nil
        end
        local bp = LocalPlayer:FindFirstChildOfClass("Backpack")
        if bp then
            local ttool = bp:FindFirstChild("tp")
            if ttool then pcall(function() ttool:Destroy() end) end
        end
        local c = LocalPlayer.Character
        if c then
            local ttool = c:FindFirstChild("tp")
            if ttool then pcall(function() ttool:Destroy() end) end
        end
    end

    local function give_tp_tool()
        remove_tp_tool()
        local bp = LocalPlayer:FindFirstChildOfClass("Backpack")
        if not bp then return end
        local tool = Instance.new("Tool")
        tool.Name = "tp"
        tool.RequiresHandle = false
        tool.CanBeDropped = false
        tool.Parent = bp
        tp_tool = tool
        tp_act_conn = tool.Activated:Connect(function()
            local root = my_hrp()
            local mouse = LocalPlayer:GetMouse()
            if not root or not mouse then return end
            local hit = mouse.Hit
            if not hit then return end
            local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = root.CFrame:components()
            tp_root(CFrame.new(hit.X, hit.Y + 3, hit.Z, r00, r01, r02, r10, r11, r12, r20, r21, r22))
            break_velocity()
        end)
    end

    getgenv().PH_TeleportToMap = teleport_to_map
    getgenv().PH_TeleportToLobby = teleport_to_lobby
    getgenv().PH_SetClickTP = function(v)
        tp_on = v and true or false
        if tp_on then
            give_tp_tool()
            if not tp_add_conn then
                tp_add_conn = LocalPlayer.CharacterAdded:Connect(function()
                    task.wait(0.5)
                    if tp_on then
                        give_tp_tool()
                    end
                end)
            end
        else
            if tp_add_conn then
                pcall(function() tp_add_conn:Disconnect() end)
                tp_add_conn = nil
            end
            remove_tp_tool()
        end
    end
end)

pcall(function()
    local gunMorphOn = false
    local gunMorphId = 1847998296
    local gunMorphName = "Fortnite Rifle"
    local gunMorphConns = {}
    local hide_conn = nil

    local gripPos = Vector3.new(0, -0.15, -0.2)
    local gripRot = Vector3.new(-90, 180, -180)
    local meshScale = Vector3.new(1, 1, 1)

    local function mute_gun_sounds(tool)
        if not tool then return end
        for _, d in ipairs(tool:GetDescendants()) do
            if d:IsA("Sound") then
                local n = string.lower(d.Name or "")
                local sid = string.lower(tostring(d.SoundId or ""))

                if n:find("gunshot") or n:find("shoot") or n:find("fire") or n:find("shot")
                    or n:find("equip") or n:find("draw") or n:find("reload")
                    or sid:find("gunshot") or sid:find("shoot") then
                    pcall(function()
                        if d:GetAttribute("PH_GM_Vol") == nil then
                            d:SetAttribute("PH_GM_Vol", d.Volume)
                        end
                        d.Volume = 0
                        d:Stop()
                    end)
                end
            end
        end
    end

    local function restore_gun_sounds(tool)
        if not tool then return end
        for _, d in ipairs(tool:GetDescendants()) do
            if d:IsA("Sound") and d:GetAttribute("PH_GM_Vol") ~= nil then
                pcall(function()
                    d.Volume = d:GetAttribute("PH_GM_Vol")
                    d:SetAttribute("PH_GM_Vol", nil)
                end)
            end
        end
    end

    local function is_under_morph(d, tool)
        local m = tool:FindFirstChild("PH_GunMorph")
        return m and d:IsDescendantOf(m)
    end

    local function clear_morph(tool)
        if not tool then return end
        local custom = tool:FindFirstChild("PH_GunMorph")
        if custom then
            pcall(function() custom:Destroy() end)
        end
        for _, d in ipairs(tool:GetDescendants()) do
            if is_under_morph(d, tool) then

            elseif d:IsA("BasePart") then
                pcall(function()
                    if d:GetAttribute("PH_GM_T") ~= nil then
                        d.Transparency = d:GetAttribute("PH_GM_T")
                        d:SetAttribute("PH_GM_T", nil)
                    end
                    if d:GetAttribute("PH_GM_LT") ~= nil then
                        d.LocalTransparencyModifier = d:GetAttribute("PH_GM_LT")
                        d:SetAttribute("PH_GM_LT", nil)
                    end
                end)
            elseif d:IsA("Decal") or d:IsA("Texture") then
                pcall(function()
                    if d:GetAttribute("PH_GM_T") ~= nil then
                        d.Transparency = d:GetAttribute("PH_GM_T")
                        d:SetAttribute("PH_GM_T", nil)
                    end
                end)
            elseif d:IsA("SpecialMesh") or d:IsA("FileMesh") then
                pcall(function()
                    if d:GetAttribute("PH_GM_S") ~= nil then
                        local s = d:GetAttribute("PH_GM_S")
                        if typeof(s) == "Vector3" then
                            d.Scale = s
                        end
                        d:SetAttribute("PH_GM_S", nil)
                    end
                end)
            end
        end
        restore_gun_sounds(tool)
    end

    local function hide_original(tool)
        if not tool then return end
        for _, d in ipairs(tool:GetDescendants()) do
            if is_under_morph(d, tool) then

            elseif d:IsA("BasePart") then
                if d:GetAttribute("PH_GM_T") == nil then
                    d:SetAttribute("PH_GM_T", d.Transparency)
                end
                if d:GetAttribute("PH_GM_LT") == nil then
                    d:SetAttribute("PH_GM_LT", d.LocalTransparencyModifier)
                end
                pcall(function()
                    d.Transparency = 1
                    d.LocalTransparencyModifier = 1
                end)
            elseif d:IsA("Decal") or d:IsA("Texture") then
                if d:GetAttribute("PH_GM_T") == nil then
                    d:SetAttribute("PH_GM_T", d.Transparency)
                end
                pcall(function()
                    d.Transparency = 1
                end)
            elseif d:IsA("SpecialMesh") or d:IsA("FileMesh") then
                if d:GetAttribute("PH_GM_S") == nil then
                    d:SetAttribute("PH_GM_S", d.Scale)
                end
                pcall(function()
                    d.Scale = Vector3.new(0, 0, 0)
                end)
            end
        end
    end

    local function load_mesh_model(assetId)
        local ok, objs = pcall(function()
            return game:GetObjects("rbxassetid://" .. tostring(assetId))
        end)
        if ok and type(objs) == "table" and objs[1] then
            return objs[1]
        end
        ok, objs = pcall(function()
            return game:GetService("InsertService"):LoadAsset(tonumber(assetId))
        end)
        if ok and objs then
            local c = objs:GetChildren()[1]
            return c or objs
        end
        return nil
    end

    local function get_handle(tool)
        local h = tool:FindFirstChild("Handle")
        if h and h:IsA("BasePart") then return h end
        for _, d in ipairs(tool:GetChildren()) do
            if d:IsA("BasePart") then return d end
        end
        for _, d in ipairs(tool:GetDescendants()) do
            if d:IsA("BasePart") then return d end
        end
        return nil
    end

    local function grip_cf()
        return CFrame.new(gripPos)
            * CFrame.Angles(math.rad(gripRot.X), math.rad(gripRot.Y), math.rad(gripRot.Z))
    end

    local function apply_to_tool(tool)
        if not tool or not tool:IsA("Tool") then return end
        if tool.Name ~= "Gun" then return end
        clear_morph(tool)
        if not gunMorphOn then return end

        local handle = get_handle(tool)
        if not handle then return end

        local wrap = Instance.new("Model")
        wrap.Name = "PH_GunMorph"
        wrap.Parent = tool

        local loaded = load_mesh_model(gunMorphId)
        local primary = nil

        if loaded then
            for _, d in ipairs(loaded:GetDescendants()) do
                if d:IsA("Script") or d:IsA("LocalScript") or d:IsA("ModuleScript") then
                    pcall(function() d:Destroy() end)
                end
            end
            if loaded:IsA("BasePart") then
                primary = loaded
                loaded.Parent = wrap
            elseif loaded:IsA("Accessory") or loaded:IsA("Hat") or loaded:IsA("Tool") then
                loaded.Parent = wrap
                primary = loaded:FindFirstChild("Handle")
                if not primary then
                    for _, d in ipairs(loaded:GetDescendants()) do
                        if d:IsA("BasePart") then
                            primary = d
                            break
                        end
                    end
                end
            elseif loaded:IsA("Model") then
                loaded.Parent = wrap
                local ok, pp = pcall(function() return loaded.PrimaryPart end)
                if ok and pp then
                    primary = pp
                else
                    for _, d in ipairs(loaded:GetDescendants()) do
                        if d:IsA("BasePart") then
                            primary = d
                            break
                        end
                    end
                end
            else
                loaded.Parent = wrap
                for _, d in ipairs(wrap:GetDescendants()) do
                    if d:IsA("BasePart") then
                        primary = d
                        break
                    end
                end
            end
        end

        if not primary then
            local p = Instance.new("Part")
            p.Name = "MorphPart"
            p.Size = Vector3.new(0.3, 0.3, 2)
            p.Massless = true
            p.CanCollide = false
            p.Anchored = false
            p.Transparency = 0
            p.Parent = wrap
            local sm = Instance.new("SpecialMesh")
            sm.MeshType = Enum.MeshType.FileMesh
            sm.MeshId = "rbxassetid://" .. tostring(gunMorphId)
            sm.Scale = meshScale
            sm.Parent = p
            primary = p
        end

        for _, d in ipairs(wrap:GetDescendants()) do
            if d:IsA("BasePart") then
                d.Massless = true
                d.CanCollide = false
                d.Anchored = false
                d.CastShadow = true
                d.Transparency = 0
                d.LocalTransparencyModifier = 0
            end
        end


        local weld = Instance.new("Weld")
        weld.Name = "MorphWeld"
        weld.Part0 = handle
        weld.Part1 = primary
        weld.C0 = grip_cf()
        weld.C1 = CFrame.new()
        weld.Parent = handle

        for _, d in ipairs(wrap:GetDescendants()) do
            if d:IsA("BasePart") and d ~= primary then
                local wc = Instance.new("WeldConstraint")
                wc.Part0 = primary
                wc.Part1 = d
                wc.Parent = primary
            end
        end

        hide_original(tool)
        mute_gun_sounds(tool)
        task.defer(function()
            hide_original(tool)
            mute_gun_sounds(tool)
        end)
        task.delay(0.15, function()
            if gunMorphOn and tool.Parent then
                hide_original(tool)
                mute_gun_sounds(tool)
            end
        end)
        if not tool:GetAttribute("PH_GM_EqHook") then
            tool:SetAttribute("PH_GM_EqHook", true)
            pcall(function()
                tool.Equipped:Connect(function()
                    if gunMorphOn then
                        task.defer(function()
                            hide_original(tool)
                            mute_gun_sounds(tool)
                        end)
                        task.delay(0.05, function()
                            mute_gun_sounds(tool)
                        end)
                        task.delay(0.2, function()
                            mute_gun_sounds(tool)
                        end)
                    end
                end)
            end)
        end
    end

    local function scan_and_apply()
        local function check(parent)
            if not parent then return end
            local gun = parent:FindFirstChild("Gun")
            if gun and gun:IsA("Tool") then
                apply_to_tool(gun)
            end
        end
        check(LocalPlayer:FindFirstChild("Backpack"))
        check(LocalPlayer.Character)
    end

    local function start_hide_loop()
        if hide_conn then
            pcall(function() hide_conn:Disconnect() end)
            hide_conn = nil
        end
        hide_conn = game:GetService("RunService").Heartbeat:Connect(function()
            if not gunMorphOn then return end
            local function tick_parent(parent)
                if not parent then return end
                local gun = parent:FindFirstChild("Gun")
                if gun and gun:FindFirstChild("PH_GunMorph") then
                    hide_original(gun)
                    mute_gun_sounds(gun)
                end
            end
            tick_parent(LocalPlayer:FindFirstChild("Backpack"))
            tick_parent(LocalPlayer.Character)
        end)
    end

    local function stop_hide_loop()
        if hide_conn then
            pcall(function() hide_conn:Disconnect() end)
            hide_conn = nil
        end
    end

    local function hook_containers()
        for _, c in ipairs(gunMorphConns) do
            pcall(function() c:Disconnect() end)
        end
        table.clear(gunMorphConns)

        local function watch(container)
            if not container then return end
            gunMorphConns[#gunMorphConns + 1] = container.ChildAdded:Connect(function(ch)
                if ch:IsA("Tool") and ch.Name == "Gun" and gunMorphOn then
                    task.defer(function()
                        apply_to_tool(ch)
                    end)
                end
            end)
        end
        watch(LocalPlayer:FindFirstChild("Backpack"))
        if LocalPlayer.Character then
            watch(LocalPlayer.Character)
        end
        gunMorphConns[#gunMorphConns + 1] = LocalPlayer.CharacterAdded:Connect(function(char)
            task.wait(0.35)
            watch(char)
            if gunMorphOn then
                scan_and_apply()
            end
        end)
        local bp = LocalPlayer:FindFirstChild("Backpack")
        if not bp then
            gunMorphConns[#gunMorphConns + 1] = LocalPlayer.ChildAdded:Connect(function(ch)
                if ch:IsA("Backpack") then
                    watch(ch)
                    if gunMorphOn then scan_and_apply() end
                end
            end)
        end
    end

    hook_containers()

    getgenv().PH_SetGunMorphId = function(id)
        gunMorphId = tonumber(id) or gunMorphId
        if gunMorphOn then
            scan_and_apply()
        end
    end

    getgenv().PH_SetGunMorphGrip = function(pos, rot)
        if typeof(pos) == "Vector3" then gripPos = pos end
        if typeof(rot) == "Vector3" then gripRot = rot end
        if gunMorphOn then scan_and_apply() end
    end

    getgenv().PH_SetGunMorphGripAxis = function(axis, value)
        value = tonumber(value) or 0
        if axis == "X" then
            gripRot = Vector3.new(value, gripRot.Y, gripRot.Z)
        elseif axis == "Y" then
            gripRot = Vector3.new(gripRot.X, value, gripRot.Z)
        elseif axis == "Z" then
            gripRot = Vector3.new(gripRot.X, gripRot.Y, value)
        elseif axis == "PX" then
            gripPos = Vector3.new(value, gripPos.Y, gripPos.Z)
        elseif axis == "PY" then
            gripPos = Vector3.new(gripPos.X, value, gripPos.Z)
        elseif axis == "PZ" then
            gripPos = Vector3.new(gripPos.X, gripPos.Y, value)
        end
        if gunMorphOn then scan_and_apply() end
    end

    getgenv().PH_SetGunMorph = function(v, id, name)
        gunMorphOn = v and true or false
        if id then gunMorphId = tonumber(id) or gunMorphId end
        if name then gunMorphName = tostring(name) end
        if gunMorphOn then
            hook_containers()
            start_hide_loop()
            scan_and_apply()
        else
            stop_hide_loop()
            local function clear_in(parent)
                if not parent then return end
                local gun = parent:FindFirstChild("Gun")
                if gun then clear_morph(gun) end
            end
            clear_in(LocalPlayer:FindFirstChild("Backpack"))
            clear_in(LocalPlayer.Character)
        end
    end

    getgenv().PH_ApplyGunMorph = function()
        if not gunMorphOn then
            gunMorphOn = true
            start_hide_loop()
        end
        scan_and_apply()
        notify("Gun Morph", gunMorphName .. " applied")
    end
end)

task.defer(function()
	local ok, err = pcall(function()
		local players = game:GetService("Players")
		local RunService = game:GetService("RunService")
		local vu = game:GetService("VirtualUser")
		local lighting = game:GetService("Lighting")
		local lp = players.LocalPlayer

		local originalBrightness = lighting.Brightness
		local originalOutdoorAmbient = lighting.OutdoorAmbient
		local originalGlobalShadows = lighting.GlobalShadows
		local originalFogEnd = lighting.FogEnd
		local originalClockTime = lighting.ClockTime

		getgenv().WORLD_FULLBRIGHT_ENABLED = false
		getgenv().WORLD_FOG_ENABLED = false
		getgenv().WORLD_FOG_END = 1000
		getgenv().WORLD_AMBIENT_ENABLED = false
		getgenv().WORLD_AMBIENT_COLOR = Color3.fromRGB(128, 128, 128)

		local anti_afk = false
		lp.Idled:Connect(function()
			if anti_afk then
				pcall(function()
					vu:CaptureController()
					vu:ClickButton2(Vector2.new())
				end)
			end
		end)
		getgenv().PH_SetAntiAFK = function(v)
			anti_afk = v and true or false
		end

		getgenv().PH_SetFullbright = function(v)
			getgenv().WORLD_FULLBRIGHT_ENABLED = v
			if v then
				lighting.Brightness = 2
				lighting.ClockTime = 14
				lighting.GlobalShadows = false
				lighting.OutdoorAmbient = Color3.fromRGB(128, 128, 128)
				if not getgenv().WORLD_FOG_ENABLED then
					lighting.FogEnd = 100000
				end
			else
				lighting.Brightness = originalBrightness
				lighting.GlobalShadows = originalGlobalShadows
				lighting.OutdoorAmbient = getgenv().WORLD_AMBIENT_ENABLED and getgenv().WORLD_AMBIENT_COLOR or originalOutdoorAmbient
				if getgenv().WORLD_FOG_ENABLED then
					lighting.FogEnd = getgenv().WORLD_FOG_END
				else
					lighting.FogEnd = originalFogEnd
				end
			end
		end

		local SOFT = "rbxasset://textures/particles/smoke_main.dds"
		local fx_on, fx_type, fx_color, fx_rate = false, "Snow", Color3.fromRGB(150, 200, 255), 250
		local fx_part, fx_emitter, fx_conn, fx_pos, fx_look = nil, nil, nil, nil, nil
		local FX_SPAN, FX_TALL = 260, 140

		local function style_emitter(t)
			local e = fx_emitter
			if not e then return end
			e.Texture = SOFT
			e.LightInfluence = 0
			e.LightEmission = 0.4
			e.ZOffset = 0
			e.Drag = 0
			e.EmissionDirection = Enum.NormalId.Bottom
			e.Rate = fx_rate
			e.Color = ColorSequence.new(fx_color)
			if t == "Snow" then
				e.Lifetime = NumberRange.new(4, 6)
				e.Speed = NumberRange.new(6, 12)
				e.Acceleration = Vector3.new(2, -6, 1)
				e.SpreadAngle = Vector2.new(35, 35)
				e.Rotation = NumberRange.new(0, 360)
				e.RotSpeed = NumberRange.new(-40, 40)
				e.Squash = NumberSequence.new(0)
				e.Size = NumberSequence.new(0.55)
				e.Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0.2),
					NumberSequenceKeypoint.new(0.8, 0.3),
					NumberSequenceKeypoint.new(1, 1)
				})
			else
				e.Lifetime = NumberRange.new(5, 7)
				e.Speed = NumberRange.new(5, 10)
				e.Acceleration = Vector3.new(4, -5, 2)
				e.SpreadAngle = Vector2.new(40, 40)
				e.Rotation = NumberRange.new(0, 360)
				e.RotSpeed = NumberRange.new(-80, 80)
				e.Squash = NumberSequence.new(1.4)
				e.Size = NumberSequence.new(0.5)
				e.Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0.15),
					NumberSequenceKeypoint.new(0.85, 0.25),
					NumberSequenceKeypoint.new(1, 1)
				})
			end
		end

		local function stop_fx()
			if fx_conn then pcall(function() fx_conn:Disconnect() end) fx_conn = nil end
			if fx_part then pcall(function() fx_part:Destroy() end) fx_part = nil end
			fx_emitter = nil
			fx_pos = nil
			fx_look = nil
		end

		local function ensure_part()
			if fx_part and fx_part.Parent then return end
			fx_part = Instance.new("Part")
			fx_part.Name = "SHITARO_WORLD_FX"
			fx_part.Anchored = true
			fx_part.CanCollide = false
			fx_part.CanQuery = false
			fx_part.CanTouch = false
			fx_part.Transparency = 1
			fx_part.Size = Vector3.new(FX_SPAN, FX_TALL, FX_SPAN)
			fx_part.Parent = workspace
			fx_emitter = Instance.new("ParticleEmitter")
			pcall(function()
				fx_emitter.Shape = Enum.ParticleEmitterShape.Box
				fx_emitter.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
			end)
			fx_emitter.Parent = fx_part
			style_emitter(fx_type)
		end

		local function burst_fx()
			if not fx_emitter then return end
			fx_emitter:Emit(math.clamp(math.floor(fx_rate * 0.16), 30, 140))
		end

		local function start_fx()
			ensure_part()
			if fx_conn then return end
			fx_pos = nil
			fx_look = nil
			fx_conn = RunService.RenderStepped:Connect(function()
				if not (fx_part and fx_part.Parent) then return end
				local cam = workspace.CurrentCamera
				if not cam then return end
				local cf = cam.CFrame
				local p = cf.Position
				local d = cf.LookVector
				local flat = Vector3.new(d.X, 0, d.Z)
				if flat.Magnitude < 0.05 then
					flat = Vector3.new(0, 0, -1)
				else
					flat = flat.Unit
				end
				if fx_pos and fx_look and (p - fx_pos).Magnitude < 10 and flat:Dot(fx_look) > 0.95 then return end
				fx_pos = p
				fx_look = flat
				fx_part.CFrame = CFrame.new(p + flat * (FX_SPAN * 0.22) + Vector3.new(0, FX_TALL * 0.5 - 26, 0))
			end)
			burst_fx()
		end

		getgenv().PH_SetWorldFX = function(v)
			fx_on = v and true or false
			if fx_on then start_fx() else stop_fx() end
		end
		getgenv().PH_SetWorldFXType = function(v)
			fx_type = type(v) == "table" and v[1] or v
			if fx_on then
				style_emitter(fx_type)
				burst_fx()
			end
		end
		getgenv().PH_SetWorldFXColor = function(c)
			fx_color = c
			if fx_emitter then fx_emitter.Color = ColorSequence.new(c) end
		end
		getgenv().PH_SetWorldFXRate = function(v)
			fx_rate = v
			if fx_emitter then
				style_emitter(fx_type)
				burst_fx()
			end
		end
	end)
	if not ok then
		warn("[KvantScript] AFK/World:", tostring(err))
	end
end)



task.defer(function()
	local ok, err = pcall(function()
		local Players = game:GetService("Players")
		local RunService = game:GetService("RunService")
		local UIS = game:GetService("UserInputService")
		local LP = Players.LocalPlayer
		local pg = LP:FindFirstChildOfClass("PlayerGui")

		local on = false
		local gui, frame, label = nil, nil, nil
		local conn = nil
		local lastText = "..."
		local roundActive = false
		local lastRoundSec = nil
		local INTERMISSION_MAX = 15

		local function ensureGui()
			if gui and gui.Parent then return end
			local parent = (gethui and gethui()) or game:GetService("CoreGui")
			gui = Instance.new("ScreenGui")
			gui.Name = "KvantRoundTimer"
			gui.ResetOnSpawn = false
			gui.IgnoreGuiInset = true
			gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
			gui.DisplayOrder = 100
			gui.Parent = parent

			frame = Instance.new("Frame")
			frame.Name = "Box"
			frame.AnchorPoint = Vector2.new(0.5, 1)
			frame.Position = UDim2.new(0.5, 0, 1, -28)
			frame.Size = UDim2.new(0, 100, 0, 30)
			frame.BackgroundColor3 = Color3.fromRGB(12, 14, 20)
			frame.BackgroundTransparency = 0.2
			frame.BorderSizePixel = 0
			frame.Active = true
			frame.Parent = gui

			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0, 8)
			corner.Parent = frame

			local stroke = Instance.new("UIStroke")
			stroke.Color = Color3.fromRGB(255, 255, 255)
			stroke.Thickness = 1.5
			stroke.Transparency = 0
			stroke.Parent = frame

			label = Instance.new("TextLabel")
			label.BackgroundTransparency = 1
			label.Size = UDim2.new(1, 0, 1, 0)
			label.Font = Enum.Font.GothamMedium
			label.TextSize = 16
			label.TextColor3 = Color3.fromRGB(245, 248, 255)
			label.TextStrokeTransparency = 0.6
			label.Text = "..."
			label.Parent = frame

			local dragging = false
			local dragStart, startPos

			local function beginDrag(input)
				dragging = true
				dragStart = input.Position
				startPos = frame.Position
				input.Changed:Connect(function()
					if input.UserInputState == Enum.UserInputState.End then
						dragging = false
					end
				end)
			end

			frame.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1
					or input.UserInputType == Enum.UserInputType.Touch then
					beginDrag(input)
				end
			end)

			UIS.InputChanged:Connect(function(input)
				if not dragging then return end
				if input.UserInputType ~= Enum.UserInputType.MouseMovement
					and input.UserInputType ~= Enum.UserInputType.Touch then
					return
				end
				local delta = input.Position - dragStart
				frame.Position = UDim2.new(
					startPos.X.Scale, startPos.X.Offset + delta.X,
					startPos.Y.Scale, startPos.Y.Offset + delta.Y
				)
			end)
		end

		local function setVisible(v)
			ensureGui()
			gui.Enabled = v and true or false
		end

		local function formatTime(sec)
			sec = math.max(0, math.floor(sec + 0.5))
			local m = math.floor(sec / 60)
			local s = sec % 60
			return string.format("%d:%02d", m, s)
		end

		local function parseTimerText(text)
			if type(text) ~= "string" then return nil end
			text = text:gsub("%s+", "")
			local m, s = text:match("^(%d+):(%d%d)$")
			if m and s then
				return tonumber(m) * 60 + tonumber(s)
			end
			return nil
		end

		local function scanCandidates()
			pg = LP:FindFirstChildOfClass("PlayerGui")
			if not pg then return {} end
			local list = {}
			local function consider(lbl)
				if not lbl or not lbl:IsA("TextLabel") then return end
				local vis = true
				pcall(function() vis = lbl.Visible end)
				if not vis then return end
				local sec = parseTimerText(lbl.Text)
				if not sec then return end
				if sec < 0 or sec > 900 then return end
				local score = sec
				local name = string.lower(lbl.Name)
				if name:find("time") or name:find("timer") or name:find("clock") then
					score = score + 50
				end
				local p = lbl.Parent
				if p then
					local pn = string.lower(p.Name)
					if pn:find("time") or pn:find("timer") or pn:find("game") then
						score = score + 30
					end
				end
				list[#list + 1] = { sec = sec, score = score }
			end
			local main = pg:FindFirstChild("MainGUI")
			if main then
				for _, d in ipairs(main:GetDescendants()) do
					if d:IsA("TextLabel") then consider(d) end
				end
			end
			if #list == 0 then
				for _, d in ipairs(pg:GetDescendants()) do
					if d:IsA("TextLabel") then consider(d) end
				end
			end
			table.sort(list, function(a, b) return a.score > b.score end)
			return list
		end

		local function pickRoundSeconds(cands)
			if not cands or #cands == 0 then return nil end
			local highest = cands[1].sec
			for i = 1, #cands do
				if cands[i].sec > highest then highest = cands[i].sec end
			end

			if not roundActive then
				if highest > INTERMISSION_MAX then
					roundActive = true
					lastRoundSec = highest
					return highest
				end
				return nil
			end

			local best = nil
			for i = 1, #cands do
				local sec = cands[i].sec
				if lastRoundSec then
					if sec <= lastRoundSec + 2 and sec >= math.max(0, lastRoundSec - 5) then
						best = sec
						break
					end
				end
				if sec > INTERMISSION_MAX then
					best = sec
					break
				end
			end
			if best then
				lastRoundSec = best
				if best <= 0 then
					roundActive = false
					lastRoundSec = nil
				end
				return best
			end
			if lastRoundSec and lastRoundSec > 0 then
				return lastRoundSec
			end
			return nil
		end

		local function inMatchAlive()
			local st = "Spectate"
			pcall(function()
				if type(refreshPlayerStatus) == "function" then
					st = refreshPlayerStatus()
				elseif type(getPlayerStatus) == "function" then
					st = getPlayerStatus()
				end
			end)
			if st ~= "Match" then
				roundActive = false
				lastRoundSec = nil
				return false
			end
			local char = LP.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if not char or not hum or hum.Health <= 0 then
				roundActive = false
				lastRoundSec = nil
				return false
			end
			return true
		end

		local function tick()
			if not on then return end
			ensureGui()
			local text = "..."
			if inMatchAlive() then
				local sec = pickRoundSeconds(scanCandidates())
				if sec then
					text = formatTime(sec)
				end
			else
				roundActive = false
				lastRoundSec = nil
			end
			if text ~= lastText then
				lastText = text
				if label then label.Text = text end
			end
		end

		getgenv().PH_SetRoundTimer = function(v)
			on = v and true or false
			roundActive = false
			lastRoundSec = nil
			lastText = "..."
			setVisible(on)
			if on then
				if label then label.Text = "..." end
				if not conn then
					conn = RunService.Heartbeat:Connect(function()
						pcall(tick)
					end)
				end
				pcall(tick)
			else
				if conn then
					pcall(function() conn:Disconnect() end)
					conn = nil
				end
				if gui then
					pcall(function() gui:Destroy() end)
					gui = nil
					frame = nil
					label = nil
				end
			end
		end
	end)
	if not ok then
		warn("[KvantScript] RoundTimer:", tostring(err))
	end
end)



task.defer(function()
	local ok, err = pcall(function()
		local Players = game:GetService("Players")
		local TweenService = game:GetService("TweenService")
		local Debris = game:GetService("Debris")
		local RunService = game:GetService("RunService")
		local SoundService = game:GetService("SoundService")
		local Lighting = game:GetService("Lighting")
		local LP = Players.LocalPlayer

		local playing = false

		local function tween(obj, time, props, style, dir)
			local tw = TweenService:Create(obj, TweenInfo.new(time, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props)
			tw:Play()
			return tw
		end

		local function hasKnife()
			local char = LP.Character
			return (LP:FindFirstChild("Backpack") and LP.Backpack:FindFirstChild("Knife"))
				or (char and char:FindFirstChild("Knife"))
		end

		local function hasGunLocal()
			local char = LP.Character
			return (LP:FindFirstChild("Backpack") and LP.Backpack:FindFirstChild("Gun"))
				or (char and char:FindFirstChild("Gun"))
		end

		local function playFallSound()
			local url = "https://raw.githubusercontent.com/DuntSunrise/DuntLibrary/refs/heads/main/car-bomba4.mp3"
			local snd = Instance.new("Sound")
			snd.Volume = 3
			snd.Looped = false
			snd.Name = "KvantNukeFall"
			snd.Parent = SoundService
			pcall(function()
				local data = game:HttpGet(url)
				local fname = "kvant_car_bomba4.mp3"
				if writefile then
					writefile(fname, data)
				end
				local asset = nil
				if getcustomasset then
					asset = getcustomasset(fname)
				elseif getsynasset then
					asset = getsynasset(fname)
				end
				if asset then
					snd.SoundId = asset
				else
					snd.SoundId = url
				end
			end)
			pcall(function() snd:Play() end)
			return snd
		end

		local function playBoomSound()
			local snd = Instance.new("Sound")
			snd.SoundId = "rbxassetid://138079951"
			snd.Volume = 3
			snd.Parent = SoundService
			pcall(function() snd:Play() end)
			Debris:AddItem(snd, 5)
		end

		local function forceHidePlayers()
			for _, plr in ipairs(Players:GetPlayers()) do
				local char = plr.Character
				if char then
					for _, d in ipairs(char:GetDescendants()) do
						if d:IsA("BasePart") then
							d.LocalTransparencyModifier = 1
						elseif d:IsA("Decal") or d:IsA("Texture") then
							pcall(function() d.Transparency = 1 end)
						elseif d:IsA("BillboardGui") or d:IsA("SurfaceGui") or d:IsA("Highlight") then
							pcall(function() d.Enabled = false end)
						end
					end
				end
			end
		end

		local function hidePlayersLocal()
			local saved = {}
			for _, plr in ipairs(Players:GetPlayers()) do
				local char = plr.Character
				if char then
					for _, d in ipairs(char:GetDescendants()) do
						if d:IsA("BasePart") then
							saved[#saved + 1] = { kind = "ltm", part = d, t = d.LocalTransparencyModifier }
							d.LocalTransparencyModifier = 1
						elseif d:IsA("Decal") or d:IsA("Texture") then
							saved[#saved + 1] = { kind = "tr", part = d, t = d.Transparency }
							pcall(function() d.Transparency = 1 end)
						elseif d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam") or d:IsA("BillboardGui") or d:IsA("SurfaceGui") or d:IsA("Highlight") then
							saved[#saved + 1] = { kind = "en", part = d, t = d.Enabled }
							pcall(function() d.Enabled = false end)
						end
					end
				end
			end
			return saved
		end

		local function restorePlayersLocal(saved)
			if not saved then return end
			for i = 1, #saved do
				local e = saved[i]
				if e.part and e.part.Parent then
					pcall(function()
						if e.kind == "ltm" then
							e.part.LocalTransparencyModifier = e.t or 0
						elseif e.kind == "tr" then
							e.part.Transparency = e.t or 0
						elseif e.kind == "en" then
							e.part.Enabled = e.t and true or false
						end
					end)
				end
			end
		end

		local function makeFireOnChar(char, duration)
			if not char then return end
			local hrp = char:FindFirstChild("HumanoidRootPart") or char:FindFirstChildWhichIsA("BasePart")
			if not hrp then return end
			local holder = Instance.new("Part")
			holder.Name = "NukeLocalFire"
			holder.Size = Vector3.new(0.2, 0.2, 0.2)
			holder.Transparency = 1
			holder.Anchored = false
			holder.CanCollide = false
			holder.CanQuery = false
			holder.CanTouch = false
			holder.Massless = true
			holder.CFrame = hrp.CFrame
			holder.Parent = workspace
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = hrp
			weld.Part1 = holder
			weld.Parent = holder
			local fire = Instance.new("Fire")
			fire.Size = 12
			fire.Heat = 10
			fire.Color = Color3.fromRGB(255, 120, 30)
			fire.SecondaryColor = Color3.fromRGB(80, 0, 0)
			fire.Parent = holder
			Debris:AddItem(holder, duration or 4)
		end

		local function loadBombModel()
			local BOMB_ID = 11481941507
			local model = nil
			pcall(function()
				if game.GetObjects then
					local objs = game:GetObjects("rbxassetid://" .. tostring(BOMB_ID))
					if objs and objs[1] then model = objs[1] end
				end
			end)
			if not model then
				pcall(function()
					local asset = game:GetService("InsertService"):LoadAsset(BOMB_ID)
					if asset then
						model = asset:IsA("Model") and asset or asset:FindFirstChildWhichIsA("Model")
						if not model then
							model = Instance.new("Model")
							for _, c in ipairs(asset:GetChildren()) do c.Parent = model end
							asset:Destroy()
						end
					end
				end)
			end
			return model
		end

		local function playNuke(cfg)
			if playing then return end
			playing = true
			cfg = cfg or {}
			local fallTime = cfg.FallTime or 9
			local signalTime = cfg.SignalTime or 9.2
			local onLand = cfg.OnLand
			local onMid = cfg.OnMid
			local midTime = cfg.MidTime or 3.5
			local onDone = cfg.OnDone
			local withSound = cfg.Sound ~= false

			local character = LP.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local hrp = character and character:FindFirstChild("HumanoidRootPart")
			local target = (hrp and hrp.Position) or Vector3.new(0, 0, 0)
			local hiddenPlayers = hidePlayersLocal()

			local camera = workspace.CurrentCamera
			local prevCameraType = camera.CameraType
			local prevCFrame = camera.CFrame
			local prevWalkSpeed, prevJumpPower
			if humanoid then
				prevWalkSpeed, prevJumpPower = humanoid.WalkSpeed, humanoid.JumpPower
				humanoid.WalkSpeed, humanoid.JumpPower = 0, 0
			end
			camera.CameraType = Enum.CameraType.Scriptable

			local prevLight = {
				Brightness = Lighting.Brightness,
				Ambient = Lighting.Ambient,
				OutdoorAmbient = Lighting.OutdoorAmbient,
				FogEnd = Lighting.FogEnd,
				FogStart = Lighting.FogStart,
				FogColor = Lighting.FogColor,
			}
			local clouds = Lighting:FindFirstChildOfClass("Clouds")
				or (workspace.Terrain and workspace.Terrain:FindFirstChildOfClass("Clouds"))
			local prevCloudsColor = nil
			if clouds then pcall(function() prevCloudsColor = clouds.Color end) end
			local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
			local prevAtmo = nil
			if atmosphere then
				pcall(function()
					prevAtmo = {
						Color = atmosphere.Color,
						Decay = atmosphere.Decay,
						Haze = atmosphere.Haze,
						Glare = atmosphere.Glare,
						Density = atmosphere.Density,
					}
				end)
			end
			local cc = Instance.new("ColorCorrectionEffect")
			cc.Name = "KvantNukeCC"
			cc.Parent = Lighting
			local skyDimConn, hideConn
			local fallStartLight = os.clock()
			local skyAcc = 0
			skyDimConn = RunService.Heartbeat:Connect(function(dt)
				skyAcc = skyAcc + dt
				if skyAcc < 0.05 then return end
				skyAcc = 0
				local a = math.clamp((os.clock() - fallStartLight) / math.max(fallTime * 0.7, 0.1), 0, 1)
				Lighting.Brightness = prevLight.Brightness + (0.2 - prevLight.Brightness) * a
				Lighting.Ambient = prevLight.Ambient:Lerp(Color3.fromRGB(25, 25, 40), a)
				Lighting.OutdoorAmbient = prevLight.OutdoorAmbient:Lerp(Color3.fromRGB(18, 18, 30), a)
				Lighting.FogStart = 0
				Lighting.FogEnd = prevLight.FogEnd + (450 - prevLight.FogEnd) * a
				Lighting.FogColor = prevLight.FogColor:Lerp(Color3.fromRGB(12, 12, 22), a)
				cc.Brightness = -0.55 * a
				cc.Contrast = 0.15 * a
				cc.Saturation = -0.35 * a
				cc.TintColor = Color3.fromRGB(255, 255, 255):Lerp(Color3.fromRGB(140, 140, 180), a)
				if clouds and prevCloudsColor then
					pcall(function() clouds.Color = prevCloudsColor:Lerp(Color3.fromRGB(8, 8, 12), a) end)
				end
				if atmosphere and prevAtmo then
					pcall(function()
						atmosphere.Color = prevAtmo.Color:Lerp(Color3.fromRGB(10, 10, 18), a)
						atmosphere.Decay = prevAtmo.Decay:Lerp(Color3.fromRGB(5, 5, 10), a)
						atmosphere.Haze = prevAtmo.Haze + (4 - prevAtmo.Haze) * a
						atmosphere.Glare = prevAtmo.Glare * (1 - a * 0.85)
						atmosphere.Density = prevAtmo.Density + (0.45 - prevAtmo.Density) * a
					end)
				end
			end)
			local hideAcc = 0
			hideConn = RunService.Heartbeat:Connect(function(dt)
				hideAcc = hideAcc + dt
				if hideAcc >= 0.1 then
					hideAcc = 0
					forceHidePlayers()
				end
			end)

			local fallSnd = playFallSound()
			local mutedSounds = {}
			local muteSeen = {}
			local function muteTree(root)
				if not root then return end
				for _, d in ipairs(root:GetDescendants()) do
					if d:IsA("Sound") and d ~= fallSnd and not muteSeen[d] then
						muteSeen[d] = true
						mutedSounds[#mutedSounds + 1] = { s = d, v = d.Volume }
						pcall(function() d.Volume = 0 end)
					end
				end
			end
			local function forceMuteAll()
				pcall(function()
					muteTree(workspace)
					muteTree(LP:FindFirstChild("PlayerGui"))
					muteTree(game:GetService("SoundService"))
					if LP.Character then muteTree(LP.Character) end
					for _, plr in ipairs(Players:GetPlayers()) do
						if plr.Character then muteTree(plr.Character) end
					end
					for i = 1, #mutedSounds do
						local e = mutedSounds[i]
						if e.s and e.s.Parent and e.s ~= fallSnd then
							pcall(function() e.s.Volume = 0 end)
						end
					end
					if fallSnd and fallSnd.Parent then
						pcall(function()
							fallSnd.Volume = 3
							if not fallSnd.IsPlaying then
								fallSnd:Play()
							end
						end)
					end
				end)
			end
			forceMuteAll()
			local muteAcc = 0
			local muteConn = RunService.Heartbeat:Connect(function(dt)
				muteAcc = muteAcc + dt
				if muteAcc >= 0.15 then
					muteAcc = 0
					forceMuteAll()
				end
			end)
			if type(onMid) == "function" then
				task.delay(midTime, function()
					if playing then
						pcall(onMid)
					end
				end)
			end

			local gui = Instance.new("ScreenGui")
			gui.Name = "KvantNukeGui"
			gui.ResetOnSpawn = false
			gui.IgnoreGuiInset = true
			gui.DisplayOrder = 999
			gui.Parent = LP:WaitForChild("PlayerGui")

			local black = Instance.new("Frame")
			black.Size = UDim2.fromScale(1, 1)
			black.BackgroundColor3 = Color3.new(0, 0, 0)
			black.BackgroundTransparency = 1
			black.BorderSizePixel = 0
			black.ZIndex = 10
			black.Parent = gui

			local flash = Instance.new("Frame")
			flash.Size = UDim2.fromScale(1, 1)
			flash.BackgroundColor3 = Color3.new(1, 1, 1)
			flash.BackgroundTransparency = 1
			flash.BorderSizePixel = 0
			flash.ZIndex = 20
			flash.Parent = gui

			local noiseLayer = Instance.new("Frame")
			noiseLayer.Size = UDim2.fromScale(1, 1)
			noiseLayer.BackgroundTransparency = 1
			noiseLayer.BorderSizePixel = 0
			noiseLayer.ZIndex = 30
			noiseLayer.ClipsDescendants = true
			noiseLayer.Parent = gui

			local signalLabel = Instance.new("TextLabel")
			signalLabel.Size = UDim2.fromScale(1, 0.22)
			signalLabel.Position = UDim2.fromScale(0, 0.39)
			signalLabel.BackgroundTransparency = 1
			signalLabel.Text = "NO SIGNAL"
			signalLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
			signalLabel.Font = Enum.Font.Code
			signalLabel.TextScaled = true
			signalLabel.TextTransparency = 1
			signalLabel.ZIndex = 50
			signalLabel.Parent = gui

			local startPos = target + Vector3.new(0, 420, 0)
			local bombModel = loadBombModel()
			local bombRoot = nil
			if bombModel then
				if not bombModel:IsA("Model") then
					local wrap = Instance.new("Model")
					bombModel.Parent = wrap
					bombModel = wrap
				end
				for _, d in ipairs(bombModel:GetDescendants()) do
					if d:IsA("BasePart") then
						d.Anchored = true
						d.CanCollide = false
						d.CanQuery = false
						d.CanTouch = false
						if not bombRoot or d.Size.Magnitude > bombRoot.Size.Magnitude then
							bombRoot = d
						end
					end
					if d:IsA("Script") or d:IsA("LocalScript") then
						pcall(function() d.Disabled = true end)
					end
				end
				if bombRoot then
					pcall(function() bombModel.PrimaryPart = bombRoot end)
					pcall(function()
						if bombModel.ScaleTo then
							bombModel:ScaleTo(math.max(bombModel:GetScale() * 3.5, 3.5))
						end
					end)
					bombModel.Name = "KvantNukeBomb"
					bombModel.Parent = workspace
				else
					bombModel:Destroy()
					bombModel = nil
				end
			end
			if not bombRoot then
				bombRoot = Instance.new("Part")
				bombRoot.Shape = Enum.PartType.Ball
				bombRoot.Size = Vector3.new(18, 18, 18)
				bombRoot.Color = Color3.fromRGB(28, 28, 32)
				bombRoot.Material = Enum.Material.Metal
				bombRoot.Anchored = true
				bombRoot.CanCollide = false
				bombRoot.CFrame = CFrame.new(startPos)
				bombRoot.Parent = workspace
				bombModel = bombRoot
			end

			local function bombCF(pos)
				return CFrame.lookAt(pos, pos + Vector3.new(0, -10, 0)) * CFrame.Angles(math.rad(90), 0, 0)
			end
			pcall(function()
				if bombModel:IsA("Model") then bombModel:PivotTo(bombCF(startPos))
				else bombRoot.CFrame = bombCF(startPos) end
			end)

			local fallStart = os.clock()
			local followConn
			followConn = RunService.RenderStepped:Connect(function()
				if not bombRoot or not bombRoot.Parent then return end
				local alpha = math.clamp((os.clock() - fallStart) / fallTime, 0, 1)
				alpha = alpha * alpha
				local pos = startPos:Lerp(target, alpha)
				local cf = bombCF(pos)
				pcall(function()
					if bombModel and bombModel:IsA("Model") then bombModel:PivotTo(cf)
					else bombRoot.CFrame = cf end
				end)
				local shake = 1.0 + alpha * 2.2
				local off = Vector3.new((math.random() - 0.5) * shake, (math.random() - 0.5) * shake * 0.35, (math.random() - 0.5) * shake)
				camera.CFrame = CFrame.new(pos + Vector3.new(38, -8, 18) + off, pos)
			end)

			task.wait(fallTime)
			if followConn then followConn:Disconnect() end
			if skyDimConn then skyDimConn:Disconnect() skyDimConn = nil end
			pcall(function()
				Lighting.Brightness = 0.2
				Lighting.Ambient = Color3.fromRGB(25, 25, 40)
				Lighting.OutdoorAmbient = Color3.fromRGB(18, 18, 30)
				Lighting.FogEnd = 450
				Lighting.FogColor = Color3.fromRGB(12, 12, 22)
				cc.Brightness = -0.55
				if clouds then clouds.Color = Color3.fromRGB(8, 8, 12) end
			end)
			if bombModel then pcall(function() bombModel:Destroy() end) end

			if type(onLand) == "function" then
				pcall(onLand)
			end

			local core = Instance.new("Part")
			core.Anchored = true
			core.CanCollide = false
			core.Transparency = 1
			core.Size = Vector3.new(1, 1, 1)
			core.CFrame = CFrame.new(target)
			core.Parent = workspace
			local fire = Instance.new("Fire")
			fire.Size = 90
			fire.Heat = 18
			fire.Parent = core
			Debris:AddItem(core, 5)
			for _, plr in ipairs(Players:GetPlayers()) do
				pcall(function() makeFireOnChar(plr.Character, 4) end)
			end

			flash.BackgroundTransparency = 0
			tween(flash, 0.35, { BackgroundTransparency = 1 })
			task.wait(0.4)
			-- stop combat effects before player sees the world again
			if type(cfg.OnBeforeReveal) == "function" then
				pcall(cfg.OnBeforeReveal)
			end
			tween(black, 0.25, { BackgroundTransparency = 0 })
			task.wait(0.3)

			local noiseBlocks = {}
			for i = 1, 18 do
				local b = Instance.new("Frame")
				b.BorderSizePixel = 0
				b.ZIndex = 32
				b.Parent = noiseLayer
				noiseBlocks[i] = b
			end
			signalLabel.TextTransparency = 0
			local noiseConn
			local t0 = os.clock()
			local noiseAcc = 0
			noiseConn = RunService.Heartbeat:Connect(function(dt)
				if not gui.Parent then return end
				if os.clock() - t0 > signalTime then return end
				noiseAcc = noiseAcc + dt
				if noiseAcc < 0.08 then return end
				noiseAcc = 0
				if math.random() < 0.35 then
					signalLabel.TextTransparency = math.random() < 0.5 and 0 or 0.55
					signalLabel.Text = ({ "NO SIGNAL", "N0 S1GNAL", "SIGNAL LOST" })[math.random(1, 3)]
				else
					signalLabel.TextTransparency = 0
					signalLabel.Text = "NO SIGNAL"
				end
				for i = 1, #noiseBlocks do
					local b = noiseBlocks[i]
					if b then
						b.Size = UDim2.fromOffset(math.random(20, 160), math.random(2, 14))
						b.Position = UDim2.new(math.random(), 0, math.random(), 0)
						local g = math.random(160, 255)
						b.BackgroundColor3 = Color3.fromRGB(g, g, g)
						b.BackgroundTransparency = 0.4 + math.random() * 0.5
					end
				end
			end)
			task.wait(signalTime)
			if noiseConn then noiseConn:Disconnect() end
			tween(black, 0.45, { BackgroundTransparency = 1 })
			task.wait(0.5)
			gui:Destroy()

			if hideConn then pcall(function() hideConn:Disconnect() end) end
			restorePlayersLocal(hiddenPlayers)
			pcall(function()
				if cc then cc:Destroy() end
				Lighting.Brightness = prevLight.Brightness
				Lighting.Ambient = prevLight.Ambient
				Lighting.OutdoorAmbient = prevLight.OutdoorAmbient
				Lighting.FogEnd = prevLight.FogEnd
				Lighting.FogStart = prevLight.FogStart
				Lighting.FogColor = prevLight.FogColor
				if clouds and prevCloudsColor then clouds.Color = prevCloudsColor end
				if atmosphere and prevAtmo then
					atmosphere.Color = prevAtmo.Color
					atmosphere.Decay = prevAtmo.Decay
					atmosphere.Haze = prevAtmo.Haze
					atmosphere.Glare = prevAtmo.Glare
					atmosphere.Density = prevAtmo.Density
				end
			end)
			camera.CameraType = prevCameraType
			if prevCameraType == Enum.CameraType.Scriptable then
				camera.CFrame = prevCFrame
			end
			if humanoid then
				humanoid.WalkSpeed = prevWalkSpeed
				humanoid.JumpPower = prevJumpPower
			end
			if muteConn then
				pcall(function() muteConn:Disconnect() end)
				muteConn = nil
			end
			if fallSnd then
				pcall(function() fallSnd:Stop() fallSnd:Destroy() end)
				fallSnd = nil
			end
			for i = 1, #mutedSounds do
				local e = mutedSounds[i]
				if e.s and e.s.Parent then
					pcall(function() e.s.Volume = e.v or 0 end)
				end
			end
			playing = false
			if type(onDone) == "function" then
				pcall(onDone)
			end
		end

		getgenv().PH_PlayNuke = playNuke

		local function equipKnife()
			pcall(function()
				local char = LP.Character
				if not char then return end
				local knife = char:FindFirstChild("Knife")
					or (LP:FindFirstChild("Backpack") and LP.Backpack:FindFirstChild("Knife"))
				if knife and knife.Parent ~= char then
					knife.Parent = char
				end
			end)
		end

		local function unequipKnife()
			pcall(function()
				local char = LP.Character
				local hum = char and char:FindFirstChildOfClass("Humanoid")
				if hum then
					hum:UnequipTools()
				end
				local knife = char and char:FindFirstChild("Knife")
				if knife and LP:FindFirstChild("Backpack") then
					knife.Parent = LP.Backpack
				end
			end)
		end

		local function murderKillWindow()
			equipKnife()
			task.wait(0.15)
			equipKnife()
			local t0 = os.clock()
			while os.clock() - t0 < 2.5 do
				equipKnife()
				pcall(function()
					if type(killAll) == "function" then
						killAll()
					end
				end)
				task.wait(0.15)
			end
			unequipKnife()
			task.defer(unequipKnife)
		end

		getgenv().PH_BigBoomMurder = function()
			local role = "Unknown"
			pcall(function()
				if type(getRole) == "function" then role = getRole(LP) end
			end)
			if role ~= "Murderer" then
				pcall(function() if notify then notify("Big Boom", "Need Murderer role") end end)
				return
			end
			if not hasKnife() then
				pcall(function() if notify then notify("Big Boom", "Need Knife") end end)
				return
			end
			pcall(function() if notify then notify("Big Boom", "Murder launch...") end end)
			playNuke({
				FallTime = 9,
				Sound = false,
				OnBeforeReveal = function()
					pcall(murderKillWindow)
				end,
				OnDone = function()
					unequipKnife()
				end,
			})
			unequipKnife()
		end

		local function stopNukeFling()
			getgenv().PH_NukeFlingStop = true
			getgenv().FLING_ACTIVE = 0
		end

		local function startNukeFling()
			getgenv().PH_NukeFlingStop = false
			task.spawn(function()
				while not getgenv().PH_NukeFlingStop do
					local targetPlr = nil
					pcall(function()
						if type(fling_role) == "function" then
							targetPlr = fling_role("Murderer")
						end
					end)
					if not targetPlr or not targetPlr.Character then
						task.wait(0.15)
					else
						pcall(function()
							if type(do_fling) == "function" then
								do_fling(targetPlr)
							end
						end)
					end
					task.wait(0.05)
				end
			end)
		end

		getgenv().PH_BigBoomSheriff = function()
			if not hasGunLocal() then
				pcall(function() if notify then notify("Big Boom", "Need Gun") end end)
				return
			end
			pcall(function() if notify then notify("Big Boom", "Sheriff launch...") end end)
			startNukeFling()
			playNuke({
				FallTime = 9,
				Sound = false,
				OnBeforeReveal = function()
					stopNukeFling()
				end,
				OnDone = function()
					stopNukeFling()
				end,
			})
			stopNukeFling()
		end

		getgenv().PH_BigBoomInnocent = function()
			pcall(function() if notify then notify("Big Boom", "Fling Murder...") end end)
			startNukeFling()
			playNuke({
				FallTime = 9,
				Sound = false,
				OnBeforeReveal = function()
					stopNukeFling()
				end,
				OnDone = function()
					stopNukeFling()
				end,
			})
			stopNukeFling()
		end
	end)
	if not ok then
		warn("[KvantScript] BigBoom:", tostring(err))
	end
end)

print("[KvantScript] Loaded")
