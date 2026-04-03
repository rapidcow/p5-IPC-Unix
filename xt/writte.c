#include <fcntl.h>
#include <unistd.h>
#include <sys/types.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>

int main(void)
{
	char const *line = "100644 tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\tnull\n";
	ssize_t written;
	int capture_errno;

	errno = 0;
	written = write(STDOUT_FILENO, line, strlen(line));
	capture_errno = errno;

	if (written < 0) {
		fprintf(stderr, "write error: %s\n", strerror(errno));
	} else {
		fprintf(stderr, "write ok; %zd of %zd chars\n",
			written, strlen(line));
	}

	return 0;
}
