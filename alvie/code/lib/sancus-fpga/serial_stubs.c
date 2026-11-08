/*
  Serial port of the FPGA target (Sancus.Fpga): opens a tty at an arbitrary baud rate (the board's UART runs at
  5 Mbaud, which termios has no constant for) with the termios2 interface of Linux (BOTHER).

  <asm/termios.h> conflicts with <termios.h>, so struct termios2 and the constants are defined here, with the
  layout of the kernel. On other systems the functions fail with a message: the FPGA target needs Linux.
*/

#include <caml/mlvalues.h>
#include <caml/fail.h>
#include <caml/memory.h>

#ifdef __linux__

#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <string.h>
#include <errno.h>
#include <stdio.h>

/* From asm/termbits.h */
#define ALVIE_BOTHER 0010000 /* c_ispeed and c_ospeed give the baud rate */
#define ALVIE_CS8 0000060
#define ALVIE_CREAD 0000200
#define ALVIE_CLOCAL 0004000
#define ALVIE_VMIN 6
#define ALVIE_VTIME 5
#define ALVIE_TCIFLUSH 0

/* The layout of the kernel's struct termios2 (44 bytes) */
struct alvie_termios2 {
  unsigned int c_iflag;
  unsigned int c_oflag;
  unsigned int c_cflag;
  unsigned int c_lflag;
  unsigned char c_line;
  unsigned char c_cc[19];
  unsigned int c_ispeed;
  unsigned int c_ospeed;
};

#define ALVIE_TCGETS2 _IOR('T', 0x2A, struct alvie_termios2)
#define ALVIE_TCSETS2 _IOW('T', 0x2B, struct alvie_termios2)
#define ALVIE_TCFLSH 0x540B

static void serial_fail(const char *what, const char *path, int err)
{
  char msg[512];
  snprintf(msg, sizeof msg, "%s %s: %s", what, path, strerror(err));
  caml_failwith(msg);
}

/* Opens path at baud baud, 8N1, raw, without flow control; reads do not block (the caller waits with select) */
CAMLprim value caml_alvie_serial_open(value v_path, value v_baud)
{
  CAMLparam2(v_path, v_baud);
  const char *path = String_val(v_path);
  int fd = open(path, O_RDWR | O_NOCTTY | O_CLOEXEC);
  if (fd < 0)
    serial_fail("Could not open", path, errno);
  struct alvie_termios2 tio;
  memset(&tio, 0, sizeof tio);
  if (ioctl(fd, ALVIE_TCGETS2, &tio) < 0) {
    int e = errno;
    close(fd);
    serial_fail("Not a serial port:", path, e);
  }
  tio.c_iflag = 0;
  tio.c_oflag = 0;
  tio.c_lflag = 0;
  tio.c_cflag = ALVIE_CS8 | ALVIE_CREAD | ALVIE_CLOCAL | ALVIE_BOTHER;
  memset(tio.c_cc, 0, sizeof tio.c_cc);
  tio.c_cc[ALVIE_VMIN] = 0;
  tio.c_cc[ALVIE_VTIME] = 0;
  tio.c_ispeed = (unsigned int)Int_val(v_baud);
  tio.c_ospeed = (unsigned int)Int_val(v_baud);
  if (ioctl(fd, ALVIE_TCSETS2, &tio) < 0) {
    int e = errno;
    close(fd);
    serial_fail("Could not configure", path, e);
  }
  ioctl(fd, ALVIE_TCFLSH, ALVIE_TCIFLUSH);
  CAMLreturn(Val_int(fd));
}

/* Discards the bytes received and not read yet */
CAMLprim value caml_alvie_serial_flush_input(value v_fd)
{
  ioctl(Int_val(v_fd), ALVIE_TCFLSH, ALVIE_TCIFLUSH);
  return Val_unit;
}

#else

CAMLprim value caml_alvie_serial_open(value v_path, value v_baud)
{
  (void)v_path;
  (void)v_baud;
  caml_failwith("The FPGA target needs Linux (it sets the baud rate of the serial port with termios2)");
}

CAMLprim value caml_alvie_serial_flush_input(value v_fd)
{
  (void)v_fd;
  return Val_unit;
}

#endif
