through = require 'through'

config = require './config'
{ currentTimeSync, log, logLevel: lvl } = require './util'

module.exports = (start, format) ->
	actualBytes = 0

	return through (chunk) ->
		# Note: Javscript dates are expressed in *ms* since epoch.
		now = currentTimeSync()

		{ maxSkew, debugMode } = config

		emit = (data) => @emit('data', data)

		# Determine bytes of PCM data per ms of music.
		{ bitDepth, channels, sampleRate } = format
		bytesPerMs = sampleRate * channels * (bitDepth / 8) / 1000

		# Maximum accepted deviation from ideal timing (ms.)
		maxSkewBytes = bytesPerMs * maxSkew

		# Determine how far off expectation the stream is.
		idealBytes = (now - start) * bytesPerMs
		diffBytes = actualBytes - idealBytes
		diffBytes -= diffBytes % 4 # Buffer is 4-byte aligned.

		if debugMode
			diffMs = diffBytes / bytesPerMs
			log(lvl.debug, "Delta: #{diffBytes} (#{diffMs.toFixed(2)}ms.)")

		# Note that we count actual bytes *of data processed* not actual bytes
		# piped out as we may remove or add data to output below.
		actualBytes += chunk.length

		return emit(chunk) if -maxSkewBytes < diffBytes < maxSkewBytes

		# Skew detected.

		log(lvl.debug, "Exceeds maximum skew of #{maxSkewBytes} (#{maxSkew}ms.)")

		# We need to take different action depending on whether we're behind
		# (underrun) or ahead (overrun) of the expected playing time.

		# In an underrun we need to effectively fast-forward and output a
		# *smaller* chunk from here to the output.

		# This means less delay in processing the next chunk and thus we 'catch up'.

		# In an overrun, we need to effectively pause and output a *larger*
		# chunk from here to the output.

		# This means more delay before processing the next chunk and thus we
		# allow the data being sent to us to 'catch up'.

		# If the underrun is so severe that we can't catch up in this chunk,
		# chunk.length + diffBytes will be <= 0. This results in a 0-size buffer
		# and we can quit early.
		correctedChunk = new Buffer(chunk.length + diffBytes)
		return emit(correctedChunk) if correctedChunk.length == 0

		if diffBytes < 0
			# Underrun.

			# We need to skip the -diffBytes we are behind by. No need to zero
			# as we fill the whole buffer with what remains.
			chunk.copy(correctedChunk, 0, -diffBytes)
		else
			# Overrun.

			# Copy the music into the start of the chunk before the 'pause'.
			chunk.copy(correctedChunk)
			# Buffers are *not* zeroed by default so clear out 'paused' portion
			# of buffer to avoid undefined (+ often horrible) sound.
			correctedChunk.fill(0, chunk.length)

		emit(correctedChunk)
