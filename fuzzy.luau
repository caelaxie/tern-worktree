--!strict
-- Fuzzy matching as fzy scores it: the query's characters must appear in
-- order; among every way they can, the best alignment wins, rewarding
-- consecutive runs and matches at word starts (after / - _ space ., or a
-- lower-to-upper case change) and charging a little per skipped character.
-- Smart case: a query with an uppercase letter matches case-sensitively.
-- Characters are UTF-8 codepoints; positions are codepoint indices.

local GAP_LEADING = -0.005
local GAP_TRAILING = -0.005
local GAP_INNER = -0.01
local MATCH_CONSECUTIVE = 1.0
local MATCH_SLASH = 0.9
local MATCH_WORD = 0.8
local MATCH_CAPITAL = 0.7
local MATCH_DOT = 0.6
local NEG = -math.huge

local M = {}

--- Splits `s` into codepoint strings (bytes, when it isn't valid UTF-8).
function M.chars(s: string): { string }
	local out: { string } = {}
	if utf8.len(s) == nil then
		for i = 1, #s do
			out[i] = s:sub(i, i)
		end
		return out
	end
	for _, c in utf8.codes(s) do
		table.insert(out, utf8.char(c))
	end
	return out
end

local function bonus(prev: string, cur: string): number
	if prev == "/" then
		return MATCH_SLASH
	elseif prev == "-" or prev == "_" or prev == " " then
		return MATCH_WORD
	elseif prev == "." then
		return MATCH_DOT
	elseif prev:match("^%l$") and cur:match("^%u$") then
		return MATCH_CAPITAL
	end
	return 0
end

--- Scores `query` against `hay`: nil when it doesn't match, else the score and
--- the matched positions in `hay` (an empty query matches with score 0).
function M.match(query: string, hay: string): (number?, { number })
	local q, h = M.chars(query), M.chars(hay)
	local n, m = #q, #h
	if n == 0 then
		return 0, {}
	end
	if n > m then
		return nil, {}
	end
	local fold = query == query:lower()
	local hk: { string } = table.create(m)
	for j = 1, m do
		hk[j] = if fold then h[j]:lower() else h[j]
	end
	-- A quick subsequence check before the quadratic part.
	local j0 = 1
	for i = 1, n do
		while j0 <= m and hk[j0] ~= q[i] do
			j0 += 1
		end
		if j0 > m then
			return nil, {}
		end
		j0 += 1
	end
	local positions: { number } = table.create(n)
	if n == m then
		for i = 1, n do
			positions[i] = i
		end
		return math.huge, positions
	end

	local bonuses: { number } = table.create(m)
	local prev = "/"
	for j = 1, m do
		bonuses[j] = bonus(prev, h[j])
		prev = h[j]
	end

	-- D[i][j]: best score with q[i] matched at h[j]; Mx[i][j]: best score of
	-- q[1..i] within h[1..j].
	local D: { { number } } = table.create(n)
	local Mx: { { number } } = table.create(n)
	for i = 1, n do
		local di, mi = table.create(m, NEG), table.create(m, NEG)
		D[i], Mx[i] = di, mi
		local prev_score = NEG
		local gap = if i == n then GAP_TRAILING else GAP_INNER
		for j = 1, m do
			if q[i] == hk[j] then
				local score = NEG
				if i == 1 then
					score = (j - 1) * GAP_LEADING + bonuses[j]
				elseif j > 1 then
					score = math.max(Mx[i - 1][j - 1] + bonuses[j], D[i - 1][j - 1] + MATCH_CONSECUTIVE)
				end
				di[j] = score
				prev_score = math.max(score, prev_score + gap)
			else
				prev_score += gap
			end
			mi[j] = prev_score
		end
	end

	-- Walk back through the matrices for the positions of the best alignment.
	local required = false
	local j = m
	for i = n, 1, -1 do
		while j >= 1 do
			if D[i][j] ~= NEG and (required or D[i][j] == Mx[i][j]) then
				required = i > 1 and j > 1 and Mx[i][j] == D[i - 1][j - 1] + MATCH_CONSECUTIVE
				positions[i] = j
				j -= 1
				break
			end
			j -= 1
		end
	end
	return Mx[n][m], positions
end

return M
