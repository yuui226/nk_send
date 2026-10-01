package com.ztransfer.lut

import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.InputStream
import java.io.OutputStream

/** Lossless float serialization of the parsed table; no image or grid resampling. */
internal object PhotoLutSnapshotCodec {
    fun write(table: CubeLut, output: OutputStream) {
        val data = DataOutputStream(output.buffered())
        data.writeInt(1); data.writeInt(table.size)
        table.domainMin.forEach(data::writeFloat)
        table.domainMax.forEach(data::writeFloat)
        table.rgb.forEach(data::writeFloat)
        data.flush()
    }
    fun read(input: InputStream, digest: String): CubeLut {
        val data = DataInputStream(input.buffered())
        require(data.readInt() == 1)
        val size = data.readInt().also { require(it in 2..CubeLutParser.MAX_SIZE) }
        val low = FloatArray(3) { data.readFloat() }
        val high = FloatArray(3) { data.readFloat() }
        val values = FloatArray(size*size*size*3) {
            data.readFloat().also { require(it.isFinite() && it in -65504f..65504f) }
        }
        require(data.read() == -1)
        for (i in 0..2) {
            val range = high[i] - low[i]
            require(low[i].isFinite() && high[i].isFinite() && range.isFinite() &&
                range >= java.lang.Float.MIN_NORMAL && (1f/range).isFinite() &&
                1f/range >= java.lang.Float.MIN_NORMAL)
        }
        return CubeLut(size, low, high, values, digest)
    }
}
