my ($fh1, $child_fh, $pid);

pipe ($fh1, $child_fh);
autoflush $child_fh 1;

unless ($pid = fork) {
	close $fh1;
    open STDOUT, '>&', $child_fh;
    close STDIN;
    exec { '/usr/bin/git' } 'git', 'mktree';
}

close $child_fh;
waitpid $pid, 0;
print <$fh1>;   # "4b825dc642cb6eb9a060e54bf8d69288fbee4904\n"
