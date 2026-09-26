/* Higher-half x86_64 kernel, loaded by Limine at its physical base
   and mapped at -2GiB (0xffffffff80000000) per the Limine boot protocol. */

ENTRY(_start)

PHDRS
{
    text    PT_LOAD    FLAGS((1 << 0) | (1 << 2)) ; /* R+X */
    rodata  PT_LOAD    FLAGS((1 << 2))             ; /* R   */
    data    PT_LOAD    FLAGS((1 << 1) | (1 << 2))  ; /* RW  */
}

SECTIONS
{
    . = 0xffffffff80000000;
    _kernel_start = .;

    .text : {
        *(.text .text.*)
    } :text

    . += CONSTANT(MAXPAGESIZE);

    .rodata : {
        *(.rodata .rodata.*)
    } :rodata

    /* Limine request pointers must be findable; kept in rodata, aligned. */
    .limine_requests : {
        KEEP(*(.limine_requests_start))
        KEEP(*(.limine_requests))
        KEEP(*(.limine_requests_end))
    } :rodata

    . += CONSTANT(MAXPAGESIZE);

    .data : {
        *(.data .data.*)
    } :data

    .bss : {
        *(COMMON)
        *(.bss .bss.*)
    } :data

    . = ALIGN(CONSTANT(MAXPAGESIZE));
    _kernel_end = .;

    /* /DISCARD/ : { */
        /* *(.eh_frame) */
        /* *(.note .note.*) */
        /* *(.comment) */
    /* } */
}
