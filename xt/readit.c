#include <fcntl.h>
#include <unistd.h>
#include <sys/types.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>

int main(void)
{
	char line[257];
	ssize_t reddit;
	int capture_errno;

	errno = 0;
	reddit = read(STDIN_FILENO, line, sizeof(line) - 1);
	capture_errno = errno;
	if (reddit >= 0) { line[reddit] = '\0'; }

	if (reddit < 0 || capture_errno) {
		fprintf(stderr, "read error: %s\n", strerror(capture_errno));
	} else {
		fprintf(stderr, "read ok; %zd of %zd chars\n",
			reddit, sizeof(line) - 1);
	}

	return 0;
}
