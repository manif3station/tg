use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp qw(tempdir);
use File::Spec;
use Digest::SHA qw(sha256_hex);
use POSIX qw(:sys_wait_h);

require D2TG::Download;

# TGT-080: D2TG::Download::download_file's dir-branch wrote directly to
# its final hash-derived path (open '>:raw' -> print -> close), with no
# atomicity guarantee. Live-reproduced (JOB-004 improvement-hunt,
# developer-dashboard:latest): forking a process that writes a large
# payload and kill -9'ing it mid-write left a truncated file at the
# final path whose real SHA256 did NOT match its own filename's claimed
# hash - and since the dedup check only tests -e (never re-hashes), that
# corrupted file would be silently trusted forever after.
#
# This test reproduces the same real-process-kill scenario against the
# new _atomic_write helper: a child process is killed mid-write, and the
# assertion is that NO file exists at the final path afterward (not a
# truncated one) - proving the write is atomic from an outside observer's
# perspective, matching the real crash this ticket fixes.

{
    my $dir     = tempdir( CLEANUP => 1 );
    my $content = 'x' x 1_000_000;
    my $hash    = sha256_hex($content);
    my $final_path = File::Spec->catfile( $dir, $hash );

    # Deterministic synchronization instead of a wall-clock race: the
    # child signals the parent via a pipe the instant its content is
    # fully written (but NOT yet renamed into place), then blocks - the
    # parent kills it only once that signal arrives, guaranteeing the
    # kill always lands strictly between "write complete" and "rename".
    # This proves the exact invariant a real, randomly-timed crash
    # mid-write relies on, without the test itself racing timing.
    pipe( my $signal_read, my $signal_write ) or die "pipe: $!";

    my $pid = fork();
    die "fork failed: $!" unless defined $pid;

    if ( $pid == 0 ) {
        close $signal_read;
        D2TG::Download::_atomic_write(
            $final_path, $content,
            after_write => sub {
                syswrite( $signal_write, '1' );
                close $signal_write;
                sleep 5;    # give the parent time to kill us before rename ever runs
            },
        );
        exit 0;    # unreachable if killed, as expected
    }

    close $signal_write;
    my $buf;
    sysread( $signal_read, $buf, 1 );    # blocks until the child confirms it finished writing
    kill 'KILL', $pid;
    waitpid( $pid, 0 );

    ok( !-e $final_path, '_atomic_write: a process killed between write-complete and rename leaves no file at all at the final path (not a truncated/corrupt one)' );
    ok( -d $dir, 'the target directory itself is unaffected' );
}

{
    # Regression: a normal (uninterrupted) write still produces the
    # correct file with the correct content at the expected path.
    my $dir     = tempdir( CLEANUP => 1 );
    my $content = 'hello world';
    my $hash    = sha256_hex($content);
    my $final_path = File::Spec->catfile( $dir, $hash );

    D2TG::Download::_atomic_write( $final_path, $content );

    ok( -e $final_path, 'a normal (uninterrupted) _atomic_write creates the file at the final path' );
    open my $fh, '<:raw', $final_path or die $!;
    local $/;
    is( <$fh>, $content, 'the file contains exactly the written content' );
    close $fh;

    # Codex review catch (TGT-080): File::Temp's own default file mode
    # (0600) is more restrictive than a plain open('>')'s (0666 & ~umask,
    # typically 0644) - the written file must match the original,
    # more-permissive default, not silently lock attachments down.
    my $expected_mode = 0666 & ~umask();
    my $actual_mode   = ( stat($final_path) )[2] & 07777;
    is( $actual_mode, $expected_mode, '_atomic_write does not leave the file more restrictively permissioned than a plain open(">") would have' );
}

done_testing();
