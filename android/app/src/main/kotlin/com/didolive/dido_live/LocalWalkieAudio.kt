package com.didolive.dido_live

import java.text.Normalizer
import java.util.Locale

internal enum class WalkieCommand {
    LEFT_SPEAKS,
    RIGHT_SPEAKS,
    CHANGE,
    CANCEL,
}

internal object LocalWalkieAudio {
    fun canCalibrate(bluetoothInputCount: Int, bluetoothOutputCount: Int): Boolean =
        bluetoothInputCount > 0 && bluetoothOutputCount > 0

    fun recognizeCommand(recognizedText: String): WalkieCommand? {
        val text = Normalizer.normalize(recognizedText, Normalizer.Form.NFD)
            .replace(Regex("\\p{Mn}+"), "")
            .lowercase(Locale.ROOT)
            .replace(Regex("[^a-z0-9 ]"), " ")
            .replace(Regex("\\s+"), " ")
            .trim()

        return when {
            Regex("\\b(izquierdo|izquierda|uno|1)\\b.*\\b(habla|hablar)\\b")
                .containsMatchIn(text) -> WalkieCommand.LEFT_SPEAKS
            Regex("\\b(derecho|derecha|dos|2)\\b.*\\b(habla|hablar)\\b")
                .containsMatchIn(text) -> WalkieCommand.RIGHT_SPEAKS
            Regex("\\bcambio\\b").containsMatchIn(text) -> WalkieCommand.CHANGE
            Regex("\\bcancela(r)? mensaje\\b").containsMatchIn(text) -> WalkieCommand.CANCEL
            else -> null
        }
    }

    fun panMonoPcm(monoPcm: ByteArray, side: String): ByteArray {
        require(side == "L" || side == "R") { "side must be L or R" }
        require(monoPcm.size % 2 == 0) { "PCM16 data must contain whole samples" }
        val stereo = ByteArray(monoPcm.size * 2)
        var source = 0
        var target = 0
        while (source < monoPcm.size) {
            if (side == "L") {
                stereo[target] = monoPcm[source]
                stereo[target + 1] = monoPcm[source + 1]
                stereo[target + 2] = 0
                stereo[target + 3] = 0
            } else {
                stereo[target] = 0
                stereo[target + 1] = 0
                stereo[target + 2] = monoPcm[source]
                stereo[target + 3] = monoPcm[source + 1]
            }
            source += 2
            target += 4
        }
        return stereo
    }
}
