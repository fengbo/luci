--[[

HTTP protocol implementation for LuCI
(c) 2008 Freifunk Leipzig / Jo-Philipp Wich <xm@leipzig.freifunk.net>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

$Id$

]]--

module("luci.http.protocol", package.seeall)

local ltn12 = require("luci.ltn12")

HTTP_MAX_CONTENT      = 1024*8		-- 8 kB maximum content size

-- Decode an urlencoded string.
-- Returns the decoded value.
function urldecode( str, no_plus )

	local function __chrdec( hex )
		return string.char( tonumber( hex, 16 ) )
	end

	if type(str) == "string" then
		if not no_plus then
			str = str:gsub( "+", " " )
		end

		str = str:gsub( "%%([a-fA-F0-9][a-fA-F0-9])", __chrdec )
	end

	return str
end


-- Extract and split urlencoded data pairs, separated bei either "&" or ";" from given url.
-- Returns a table value with urldecoded values.
function urldecode_params( url, tbl )

	local params = tbl or { }

	if url:find("?") then
		url = url:gsub( "^.+%?([^?]+)", "%1" )
	end

	for pair in url:gmatch( "[^&;]+" ) do

		-- find key and value
		local key = urldecode( pair:match("^([^=]+)")     )
		local val = urldecode( pair:match("^[^=]+=(.+)$") )

		-- store
		if type(key) == "string" and key:len() > 0 then
			if type(val) ~= "string" then val = "" end

			if not params[key] then
				params[key] = val
			elseif type(params[key]) ~= "table" then
				params[key] = { params[key], val }
			else
				table.insert( params[key], val )
			end
		end
	end

	return params
end


-- Encode given string in urlencoded format.
-- Returns the encoded string.
function urlencode( str )

	local function __chrenc( chr )
		return string.format(
			"%%%02x", string.byte( chr )
		)
	end

	if type(str) == "string" then
		str = str:gsub(
			"([^a-zA-Z0-9$_%-%.%+!*'(),])",
			__chrenc
		)
	end

	return str
end


-- Encode given table to urlencoded string.
-- Returns the encoded string.
function urlencode_params( tbl )
	local enc = ""

	for k, v in pairs(tbl) do
		enc = enc .. ( enc and "&" or "" ) ..
			urlencode(k) .. "="  ..
			urlencode(v)
	end

	return enc
end


-- Parameter helper
local function __initval( tbl, key )
	if tbl[key] == nil then
		tbl[key] = ""
	elseif type(tbl[key]) == "string" then
		tbl[key] = { tbl[key], "" }
	else
		table.insert( tbl[key], "" )
	end
end

local function __appendval( tbl, key, chunk )
	if type(tbl[key]) == "table" then
		tbl[key][#tbl[key]] = tbl[key][#tbl[key]] .. chunk
	else
		tbl[key] = tbl[key] .. chunk
	end
end

local function __finishval( tbl, key, handler )
	if handler then
		if type(tbl[key]) == "table" then
			tbl[key][#tbl[key]] = handler( tbl[key][#tbl[key]] )
		else
			tbl[key] = handler( tbl[key] )
		end
	end
end


-- Table of our process states
local process_states = { }

-- Extract "magic", the first line of a http message.
-- Extracts the message type ("get", "post" or "response"), the requested uri
-- or the status code if the line descripes a http response.
process_states['magic'] = function( msg, chunk, err )

	if chunk ~= nil then
		-- ignore empty lines before request
		if #chunk == 0 then
			return true, nil
		end

		-- Is it a request?
		local method, uri, http_ver = chunk:match("^([A-Z]+) ([^ ]+) HTTP/([01]%.[019])$")

		-- Yup, it is
		if method then

			msg.type           = "request"
			msg.request_method = method:lower()
			msg.request_uri    = uri
			msg.http_version   = tonumber( http_ver )
			msg.headers        = { }

			-- We're done, next state is header parsing
			return true, function( chunk )
				return process_states['headers']( msg, chunk )
			end

		-- Is it a response?
		else

			local http_ver, code, message = chunk:match("^HTTP/([01]%.[019]) ([0-9]+) ([^\r\n]+)$")

			-- Is a response
			if code then

				msg.type           = "response"
				msg.status_code    = code
				msg.status_message = message
				msg.http_version   = tonumber( http_ver )
				msg.headers        = { }

				-- We're done, next state is header parsing
				return true, function( chunk )
					return process_states['headers']( msg, chunk )
				end
			end
		end
	end

	-- Can't handle it
	return nil, "Invalid HTTP message magic"
end


-- Extract headers from given string.
process_states['headers'] = function( msg, chunk )

	if chunk ~= nil then

		-- Look for a valid header format
		local hdr, val = chunk:match( "^([A-Z][A-Za-z0-9%-_]+): +(.+)$" )

		if type(hdr) == "string" and hdr:len() > 0 and
		   type(val) == "string" and val:len() > 0
		then
			msg.headers[hdr] = val

			-- Valid header line, proceed
			return true, nil

		elseif #chunk == 0 then
			-- Empty line, we won't accept data anymore
			return false, nil
		else
			-- Junk data
			return nil, "Invalid HTTP header received"
		end
	else
		return nil, "Unexpected EOF"
	end
end


-- Creates a header source from a given socket
function header_source( sock )
	return ltn12.source.simplify( function()

		local chunk, err, part = sock:receive("*l")

		-- Line too long
		if chunk == nil then
			if err ~= "timeout" then
				return nil, part
					and "Line exceeds maximum allowed length"
					or  "Unexpected EOF"
			else
				return nil, err
			end

		-- Line ok
		elseif chunk ~= nil then

			-- Strip trailing CR
			chunk = chunk:gsub("\r$","")

			return chunk, nil
		end
	end )
end


-- Decode MIME encoded data.
function mimedecode_message_body( src, msg, filecb )

	if msg and msg.env.CONTENT_TYPE then
		msg.mime_boundary = msg.env.CONTENT_TYPE:match("^multipart/form%-data; boundary=(.+)$")
	end

	if not msg.mime_boundary then
		return nil, "Invalid Content-Type found"
	end


	local tlen   = 0
	local inhdr  = false
	local field  = nil
	local store  = nil
	local lchunk = nil

	local function parse_headers( chunk, field )

		local stat
		repeat
			chunk, stat = chunk:gsub(
				"^([A-Z][A-Za-z0-9%-_]+): +([^\r\n]+)\r\n",
				function(k,v)
					field.headers[k] = v
					return ""
				end
			)
		until stat == 0

		chunk, stat = chunk:gsub("^\r\n","")

		-- End of headers
		if stat > 0 then
			if field.headers["Content-Disposition"] then
				if field.headers["Content-Disposition"]:match("^form%-data; ") then
					field.name = field.headers["Content-Disposition"]:match('name="(.-)"')
					field.file = field.headers["Content-Disposition"]:match('filename="(.+)"$')
				end
			end

			if not field.headers["Content-Type"] then
				field.headers["Content-Type"] = "text/plain"
			end

			if field.name and field.file and filecb then
				__initval( msg.params, field.name )
				__appendval( msg.params, field.name, field.file )

				store = filecb
			elseif field.name then
				__initval( msg.params, field.name )

				store = function( hdr, buf, eof )
					__appendval( msg.params, field.name, buf )
				end
			else
				store = nil
			end

			return chunk, true
		end

		return chunk, false
	end

	local function snk( chunk )

		tlen = tlen + ( chunk and #chunk or 0 )

		if msg.env.CONTENT_LENGTH and tlen > tonumber(msg.env.CONTENT_LENGTH) + 2 then
			return nil, "Message body size exceeds Content-Length"
		end

		if chunk and not lchunk then
			lchunk = "\r\n" .. chunk

		elseif lchunk then
			local data = lchunk .. ( chunk or "" )
			local spos, epos, found

			repeat
				spos, epos = data:find( "\r\n--" .. msg.mime_boundary .. "\r\n", 1, true )

				if not spos then
					spos, epos = data:find( "\r\n--" .. msg.mime_boundary .. "--\r\n", 1, true )
				end


				if spos then
					local predata = data:sub( 1, spos - 1 )

					if inhdr then
						predata, eof = parse_headers( predata, field )

						if not eof then
							return nil, "Invalid MIME section header"
						elseif not field.name then
							return nil, "Invalid Content-Disposition header"
						end
					end

					if store then
						store( field.headers, predata, true )
					end


					field = { headers = { } }
					found = found or true

					data, eof = parse_headers( data:sub( epos + 1, #data ), field )
					inhdr = not eof
				end
			until not spos

			if found then
				if #data > 78 then
					lchunk = data:sub( #data - 78 + 1, #data )
					data   = data:sub( 1, #data - 78 )

					if store then
						store( field.headers, data, false )
					else
						return nil, "Invalid MIME section header"
					end
				else
					lchunk, data = data, nil
				end
			else
				if inhdr then
					lchunk, eof = parse_headers( data, field )
					inhdr = not eof
				else
					store( field.headers, lchunk, false )
					lchunk, chunk = chunk, nil
				end
			end
		end

		return true
	end

	return ltn12.pump.all( src, snk )
end


-- Decode urlencoded data.
function urldecode_message_body( src, msg )

	local tlen   = 0
	local lchunk = nil

	local function snk( chunk )

		tlen = tlen + ( chunk and #chunk or 0 )

		if msg.env.CONTENT_LENGTH and tlen > tonumber(msg.env.CONTENT_LENGTH) + 2 then
			return nil, "Message body size exceeds Content-Length"
		elseif tlen > HTTP_MAX_CONTENT then
			return nil, "Message body size exceeds maximum allowed length"
		end

		if not lchunk and chunk then
			lchunk = chunk

		elseif lchunk then
			local data = lchunk .. ( chunk or "&" )
			local spos, epos

			repeat
				spos, epos = data:find("^.-[;&]")

				if spos then
					local pair = data:sub( spos, epos - 1 )
					local key  = pair:match("^(.-)=")
					local val  = pair:match("=(.*)$")

					if key and #key > 0 then
						__initval( msg.params, key )
						__appendval( msg.params, key, val )
						__finishval( msg.params, key, urldecode )
					end

					data = data:sub( epos + 1, #data )
				end
			until not spos

			lchunk = data
		end

		return true
	end

	return ltn12.pump.all( src, snk )
end


-- Parse a http message header
function parse_message_header( source )

	local ok   = true
	local msg  = { }

	local sink = ltn12.sink.simplify(
		function( chunk )
			return process_states['magic']( msg, chunk )
		end
	)

	-- Pump input data...
	while ok do

		-- get data
		ok, err = ltn12.pump.step( source, sink )

		-- error
		if not ok and err then
			return nil, err

		-- eof
		elseif not ok then

			-- Process get parameters
			if ( msg.request_method == "get" or msg.request_method == "post" ) and
			   msg.request_uri:match("?")
			then
				msg.params = urldecode_params( msg.request_uri )
			else
				msg.params = { }
			end

			-- Populate common environment variables
			msg.env = {
				CONTENT_LENGTH    = msg.headers['Content-Length'];
				CONTENT_TYPE      = msg.headers['Content-Type'];
				REQUEST_METHOD    = msg.request_method:upper();
				REQUEST_URI       = msg.request_uri;
				SCRIPT_NAME       = msg.request_uri:gsub("?.+$","");
				SCRIPT_FILENAME   = "";		-- XXX implement me
				SERVER_PROTOCOL   = "HTTP/" .. string.format("%.1f", msg.http_version)
			}

			-- Populate HTTP_* environment variables
			for i, hdr in ipairs( {
				'Accept',
				'Accept-Charset',
				'Accept-Encoding',
				'Accept-Language',
				'Connection',
				'Cookie',
				'Host',
				'Referer',
				'User-Agent',
			} ) do
				local var = 'HTTP_' .. hdr:upper():gsub("%-","_")
				local val = msg.headers[hdr]

				msg.env[var] = val
			end
		end
	end

	return msg
end


-- Parse a http message body
function parse_message_body( source, msg, filecb )
	-- Is it multipart/mime ?
	if msg.env.REQUEST_METHOD == "POST" and msg.env.CONTENT_TYPE and
	   msg.env.CONTENT_TYPE:match("^multipart/form%-data")
	then

		return mimedecode_message_body( source, msg, filecb )

	-- Is it application/x-www-form-urlencoded ?
	elseif msg.env.REQUEST_METHOD == "POST" and msg.env.CONTENT_TYPE and
	       msg.env.CONTENT_TYPE == "application/x-www-form-urlencoded"
	then
		return urldecode_message_body( source, msg, filecb )


	-- Unhandled encoding
	-- If a file callback is given then feed it chunk by chunk, else
	-- store whole buffer in message.content
	else

		local sink

		-- If we have a file callback then feed it
		if type(filecb) == "function" then
			sink = filecb

		-- ... else append to .content
		else
			msg.content = ""
			msg.content_length = 0

			sink = function( chunk )
				if ( msg.content_length + #chunk ) <= HTTP_MAX_CONTENT then

					msg.content        = msg.content        .. chunk
					msg.content_length = msg.content_length + #chunk

					return true
				else
					return nil, "POST data exceeds maximum allowed length"
				end
			end
		end

		-- Pump data...
		while true do
			local ok, err = ltn12.pump.step( source, sink )

			if not ok and err then
				return nil, err
			elseif not err then
				return true
			end
		end
	end
end

-- Status codes
statusmsg = {
	[200] = "OK",
	[301] = "Moved Permanently",
	[304] = "Not Modified",
	[400] = "Bad Request",
	[403] = "Forbidden",
	[404] = "Not Found",
	[405] = "Method Not Allowed",
	[411] = "Length Required",
	[412] = "Precondition Failed",
	[500] = "Internal Server Error",
	[503] = "Server Unavailable",
}
