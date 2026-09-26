ENTRY(_start)

PHDRS
{
    text    PT_LOAD    FLAGS((1 << 0) | (1 << 2)) ; /* R+X */
    rodata  PT_LOAD    FLAGS((1 << 2))            ; /* R   */
    data    PT_LOAD    FLAGS((1 << 1) | (1 << 2)) ; /* RW  */
}

SECTIONS
{
    . = 0x0;

    .text : {
        *(.text .text.*)
    } :text

    . += CONSTANT(MAXPAGESIZE);

    .rodata : {
        *(.rodata .rodata.*)
    } :rodata

    . += CONSTANT(MAXPAGESIZE);

    .data : {
        *(.data .data.*)
    } :data

    .bss : {
        *(COMMON)
        *(.bss .bss.*)
    } :data

    /* /DISCARD/ : { */
        /* *(.eh_frame) */
        /* *(.note .note.*) */
        /* *(.comment) */
    /* } */
}
