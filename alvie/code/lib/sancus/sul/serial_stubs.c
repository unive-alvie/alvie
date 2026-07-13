/* serial_stubs.c — set custom baud rates via termios2/BOTHER on Linux.
   <asm/termios.h> conflicts with <termios.h>, so we define the struct inline
   using the same layout as the kernel (44 bytes, no padding). */

#define _GNU_SOURCE
#include <caml/mlvalues.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <string.h>
#include <errno.h>

/* Octal constants from asm/termbits.h */
#define BOTHER   0010000   /* use c_ispeed / c_ospeed directly */
#define CS8      0000060
#define CREAD    0000200
#define CLOCAL   0004000
#define VMIN     6         /* c_cc index */
#define VTIME    5         /* c_cc index */
#define TCIFLUSH 0

/* termios2: layout must match the kernel exactly (44 bytes on all arches) */
struct termios2 {
    unsigned int  c_iflag;
    unsigned int  c_oflag;
    unsigned int  c_cflag;
    unsigned int  c_lflag;
    unsigned char c_line;
    unsigned char c_cc[19];   /* NCCS = 19 for termios2 */
    unsigned int  c_ispeed;
    unsigned int  c_ospeed;
};

/* ioctl numbers derived via _IOR/_IOW with sizeof(struct termios2) = 44 */
#define TCGETS2  _IOR('T', 0x2A, struct termios2)
#define TCSETS2  _IOW('T', 0x2B, struct termios2)
#define TCFLSH   0x540B

/* Open a serial port and configure it at `baud` baud (8N1, raw, no flow control).
   Returns the file descriptor as an OCaml Unix.file_descr (= Val_int). */
CAMLprim value caml_serial_open_baud(value v_path, value v_baud)
{
    CAMLparam2(v_path, v_baud);
    const char *path = String_val(v_path);
    int baud = Int_val(v_baud);

    int fd = open(path, O_RDWR | O_NOCTTY);
    if (fd < 0)
        caml_failwith(strerror(errno));

    struct termios2 tio;
    memset(&tio, 0, sizeof(tio));
    if (ioctl(fd, TCGETS2, &tio) < 0) {
        int e = errno; close(fd);
        caml_failwith(strerror(e));
    }

    tio.c_iflag = 0;
    tio.c_oflag = 0;
    tio.c_lflag = 0;
    tio.c_cflag = CS8 | CREAD | CLOCAL | BOTHER;
    memset(tio.c_cc, 0, sizeof(tio.c_cc));
    tio.c_cc[VMIN]  = 0;  /* non-blocking reads; we use select() for timeout */
    tio.c_cc[VTIME] = 0;
    tio.c_ispeed = (unsigned int)baud;
    tio.c_ospeed = (unsigned int)baud;

    if (ioctl(fd, TCSETS2, &tio) < 0) {
        int e = errno; close(fd);
        caml_failwith(strerror(e));
    }

    /* Drain any stale data in the receive buffer */
    ioctl(fd, TCFLSH, TCIFLUSH);

    CAMLreturn(Val_int(fd));
}

/* Flush the serial receive buffer (discard unread bytes). [@@noalloc] safe. */
CAMLprim value caml_serial_flush_input(value v_fd)
{
    ioctl(Int_val(v_fd), TCFLSH, TCIFLUSH);
    return Val_unit;
}
