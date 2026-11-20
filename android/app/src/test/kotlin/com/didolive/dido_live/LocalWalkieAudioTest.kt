package com.didolive.dido_live

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class LocalWalkieAudioTest {
    @Test
    fun oneBluetoothAddressAndInputAllowCalibration() {
        assertEquals(true, LocalWalkieAudio.canCalibrate(1, 1))
        assertEquals(false, LocalWalkieAudio.canCalibrate(0, 1))
        assertEquals(false, LocalWalkieAudio.canCalibrate(1, 0))
    }

    @Test
    fun recognizedSpanishCommandsMapToTheFourActions() {
        assertEquals(
            WalkieCommand.LEFT_SPEAKS,
            LocalWalkieAudio.recognizeCommand("Dido izquierdo habla"),
        )
        assertEquals(
            WalkieCommand.LEFT_SPEAKS,
            LocalWalkieAudio.recognizeCommand("Dido 1 habla"),
        )
        assertEquals(
            WalkieCommand.RIGHT_SPEAKS,
            LocalWalkieAudio.recognizeCommand("Dido derecho habla"),
        )
        assertEquals(
            WalkieCommand.RIGHT_SPEAKS,
            LocalWalkieAudio.recognizeCommand("Dido dos habla"),
        )
        assertEquals(WalkieCommand.CHANGE, LocalWalkieAudio.recognizeCommand("Cambio"))
        assertEquals(
            WalkieCommand.CANCEL,
            LocalWalkieAudio.recognizeCommand("Cancela mensaje"),
        )
        assertEquals(null, LocalWalkieAudio.recognizeCommand("hola"))
    }

    @Test
    fun monoPcmIsInterleavedIntoOnlyTheRequestedStereoChannel() {
        val mono = byteArrayOf(0x34, 0x12, 0x00, 0x80.toByte())

        assertArrayEquals(
            byteArrayOf(0x34, 0x12, 0, 0, 0x00, 0x80.toByte(), 0, 0),
            LocalWalkieAudio.panMonoPcm(mono, "L"),
        )
        assertArrayEquals(
            byteArrayOf(0, 0, 0x34, 0x12, 0, 0, 0x00, 0x80.toByte()),
            LocalWalkieAudio.panMonoPcm(mono, "R"),
        )
    }
}
