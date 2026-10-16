package com.opencapture.opencine.vocabulary

/**
 * The two header readouts that describe how a clip is recorded. Both open the same popup: codec
 * and colour are one decision on a camera whose colour choices depend on the codec.
 * Swift twin: `CaptureCodecColorReadout`.
 */
enum class CaptureCodecColorReadout {
    CODEC,
    COLOR,
    ;

    /** The popup a tap on this readout opens. There is only one. */
    val popup: CaptureCodecColorPopup get() = CaptureCodecColorPopup.CODEC_COLOR
}

/** The one codec and colour popup. */
enum class CaptureCodecColorPopup { CODEC_COLOR }

/** The popup's sections, in display order. */
enum class CaptureCodecColorSection { CODEC, COLOR }

/**
 * One choice the camera offers. The identity is integration-owned (an advertised raw value, a
 * profile name), never a label match; the label is the camera's own name for it. [isEditable] is
 * false for a value the camera reports but does not let the operator change, such as a colour
 * fixed by the codec (R3D records Log3G10 only). Swift twin: `CaptureCodecColorChoice`.
 */
data class CaptureCodecColorChoice(
    val id: String,
    val label: String,
    val isEditable: Boolean = true,
)

/**
 * What the codec and colour popup lists: only what the camera offers. A camera without codec
 * choices shows colour alone; colour choices are the ones valid for the selected codec, as the
 * camera reports them. An unknown selection is null, never the first choice.
 * Swift twin: `CaptureCodecColorChoices`.
 */
class CaptureCodecColorChoices(
    codecs: List<CaptureCodecColorChoice> = emptyList(),
    selectedCodec: String? = null,
    colors: List<CaptureCodecColorChoice> = emptyList(),
    selectedColor: String? = null,
) {
    val codecs: List<CaptureCodecColorChoice> = codecs.distinctBy { it.id }
    val colors: List<CaptureCodecColorChoice> = colors.distinctBy { it.id }
    val selectedCodec: String? = selectedCodec?.takeIf { id -> this.codecs.any { it.id == id } }
    val selectedColor: String? = selectedColor?.takeIf { id -> this.colors.any { it.id == id } }

    val showsCodec: Boolean get() = codecs.isNotEmpty()
    val showsColor: Boolean get() = colors.isNotEmpty()
    val isEmpty: Boolean get() = codecs.isEmpty() && colors.isEmpty()

    val sections: List<CaptureCodecColorSection>
        get() = listOfNotNull(
            CaptureCodecColorSection.CODEC.takeIf { showsCodec },
            CaptureCodecColorSection.COLOR.takeIf { showsColor },
        )

    /** The popup header: names only the sections the camera offers. */
    val title: String
        get() = when {
            showsCodec && showsColor -> "CODEC · COLOR"
            showsCodec -> "CODEC"
            else -> "COLOR"
        }

    val codecEditable: Boolean get() = codecs.any { it.isEditable }
    val colorEditable: Boolean get() = colors.any { it.isEditable }

    val selectedCodecChoice: CaptureCodecColorChoice? get() = selectedCodec?.let { id -> codecs.firstOrNull { it.id == id } }
    val selectedColorChoice: CaptureCodecColorChoice? get() = selectedColor?.let { id -> colors.firstOrNull { it.id == id } }

    override fun equals(other: Any?): Boolean =
        other is CaptureCodecColorChoices && codecs == other.codecs && colors == other.colors &&
            selectedCodec == other.selectedCodec && selectedColor == other.selectedColor

    override fun hashCode(): Int = listOf(codecs, selectedCodec, colors, selectedColor).hashCode()

    override fun toString(): String =
        "CaptureCodecColorChoices(codecs=$codecs, selectedCodec=$selectedCodec, colors=$colors, selectedColor=$selectedColor)"

    companion object {
        val EMPTY = CaptureCodecColorChoices()
    }
}
