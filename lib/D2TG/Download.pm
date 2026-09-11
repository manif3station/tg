package D2TG::Download;

use strict;
use warnings;
use LWP::UserAgent;
use File::Temp qw(tempfile);
use File::Spec;
use Digest::SHA qw(sha256_hex);
use D2TG::Config;
use D2TG::Poller;

use constant DEFAULT_HARD_TIMEOUT => 50;

sub download_file {
    my ( $telegram, $file_id, %args ) = @_;

    my $file_path = $telegram->get_file($file_id);
    die "D2TG::Download::download_file: no file_path returned for $file_id\n"
      unless defined $file_path;

    my $ua  = $args{ua} || LWP::UserAgent->new( timeout => DEFAULT_HARD_TIMEOUT );
    my $url = $telegram->file_download_url($file_path);

    my $timeout = $args{timeout} || eval { $ua->timeout } || DEFAULT_HARD_TIMEOUT;
    my $res = D2TG::Config::_with_hard_timeout( $timeout, 'D2TG::Download::download_file', sub { $ua->get($url) } );
    die "D2TG::Download::download_file: HTTP request failed (status @{[ $res->code ]} @{[ $res->message ]})\n"
      unless $res->is_success;

    my $content = $res->decoded_content( charset => 'none' );
    my $suffix  = $file_path =~ /(\.[A-Za-z0-9]+)$/ ? $1 : '';

    if ( defined $args{dir} ) {
        my $hash       = sha256_hex($content);
        my $local_path = File::Spec->catfile( $args{dir}, "$hash$suffix" );

        if ( -e $local_path ) {
            my $now = time();
            utime $now, $now, $local_path;
        }
        else {
            _atomic_write( $local_path, $content );
        }

        return $local_path;
    }

    my ( $fh, $local_path ) = tempfile( SUFFIX => $suffix, UNLINK => 0 );
    binmode $fh;
    print {$fh} $content;
    close $fh;

    return $local_path;
}


sub _atomic_write {
    my ( $path, $content, %opts ) = @_;

    my ($dir) = $path =~ m{^(.*)/[^/]+$};
    $dir = '.' unless defined $dir;

    my ( $fh, $tmp_path ) = tempfile( DIR => $dir, SUFFIX => '.tmp', UNLINK => 0 );
    binmode $fh, ':raw';
    print {$fh} $content
      or die "D2TG::Download::_atomic_write: cannot write $tmp_path: $!\n";
    close $fh
      or die "D2TG::Download::_atomic_write: cannot close $tmp_path: $!\n";

    # File::Temp creates its file mode 0600, unlike the plain open('>')
    # this replaces (which got the usual 0666 & ~umask, typically 0644) -
    # match that original, more permissive default so downloaded
    # attachments remain as readable as they always were (a Codex review
    # catch during TGT-080).
    chmod( 0666 & ~umask(), $tmp_path );

    # Test-only synchronization point (TGT-080): lets a test deterministically
    # kill this process strictly between "content fully written" and "rename",
    # proving a crash there can never leave anything at $path - the same
    # invariant a real, randomly-timed crash mid-write relies on, without the
    # test itself needing to race real wall-clock timing.
    $opts{after_write}->() if $opts{after_write};

    rename $tmp_path, $path
      or die "D2TG::Download::_atomic_write: cannot rename $tmp_path to $path: $!\n";

    return;
}

sub retry_failed_download {
    my ( $telegram, $store, $row, $dir, %args ) = @_;

    my $local_path = eval { download_file( $telegram, $row->{file_id}, dir => $dir, ua => $args{ua} ) };

    if ($@) {
        my $error = $@;
        $error =~ s/\n\z//;
        return ( 0, $error );
    }

    # TGT-104, Codex review finding: a retry success used to only
    # remove the queue row, leaving nothing in D2TG::Store's own
    # message history the way a first-time success already gets via
    # D2TG::Poller's own record_message call - restore it the same way.
    #
    # TGT-194 (found via a scheduled JOB-003 hourly bug hunt, reproduced
    # live in a developer-dashboard:latest container, the same class of
    # issue as TGT-132/165/166/186/190/191/192/193): both of these
    # D2TG::Store calls used to run unwrapped - a locked/busy database
    # at either one died raw straight out of this function, breaking
    # its own documented (1, $local_path)/(0, $error) return contract
    # even though the download itself genuinely succeeded, and (since
    # cli/retry-download.pl's own batch loop has no eval around this
    # call either) crashing the whole script mid-loop, silently
    # abandoning every remaining queued row in that batch. Now
    # eval-wrapped and classified via D2TG::Poller::_classify_store_error,
    # matching the established pattern - a bookkeeping-write failure is
    # logged non-fatally to STDERR and does not affect the reported
    # (1, $local_path) success, since the download itself did succeed.
    if ( defined $row->{media_kind} ) {
        # TGT-133: the summary text (shown verbatim by cli/history.pl and
        # cli/unread.pl) must never contain the real local path - only
        # local_path (a separate, narrow-accessor-only column) does.
        my $summary = "$row->{media_kind}" . ( $row->{caption_note} // '' );
        eval { $store->record_message( $row->{chat_id}, $row->{message_id}, $row->{sender}, $summary, local_path => $local_path ) };
        if ($@) {
            my $reason = D2TG::Poller::_classify_store_error($@);
            print STDERR "STORE ERROR [$row->{chat_id}]: record_message failed - $reason\n";
        }
    }

    eval { $store->remove_failed_download( $row->{id} ) };
    if ($@) {
        my $reason = D2TG::Poller::_classify_store_error($@);
        print STDERR "STORE ERROR [$row->{chat_id}]: remove_failed_download failed - $reason\n";
    }

    return ( 1, $local_path );
}

sub prune_vault {
    my ( $dir, %args ) = @_;
    my $max_bytes = $args{max_bytes} // 100 * 1024 * 1024;

    opendir my $dh, $dir or return;
    my @files = grep { -f "$dir/$_" } readdir $dh;
    closedir $dh;

    my @entries = map {
        my $path = File::Spec->catfile( $dir, $_ );
        my @stat = stat $path;
        { path => $path, size => $stat[7], mtime => $stat[9] };
    } @files;

    my $total = 0;
    $total += $_->{size} for @entries;

    return if $total <= $max_bytes;

    for my $entry ( sort { $a->{mtime} <=> $b->{mtime} } @entries ) {
        last if $total <= $max_bytes;
        unlink $entry->{path} and $total -= $entry->{size};
    }

    return;
}

1;

=head1 NAME

D2TG::Download - download a Telegram-hosted file to a local temp file

=head1 SYNOPSIS

    my $local_path = D2TG::Download::download_file( $telegram, $file_id );

=head1 DESCRIPTION

Resolves C<$file_id> to a C<file_path> via the given L<D2TG::Telegram>
object's C<get_file>, then downloads it via C<file_download_url>,
preserving the original file extension.

=head1 FUNCTIONS

=head2 download_file($telegram, $file_id, ua => $optional_client, dir => $optional_dir, timeout => $optional_seconds)

Returns the local path to the downloaded file. Dies if C<get_file>
returns no C<file_path>, or if the download request fails. C<ua> is
optional and defaults to L<LWP::UserAgent> with an explicit
C<timeout =E<gt> DEFAULT_HARD_TIMEOUT> (TGT-028, TGT-126); tests inject a
fake here instead.

The underlying HTTP GET (TGT-126, same failure class as
L<D2TG::Telegram>'s own TGT-044 incident) is wrapped in
L<D2TG::Config/_with_hard_timeout>
so a connection stuck in TCP C<connect()> - which a plain C<LWP::UserAgent>
C<timeout> does not reliably bound - still dies with a clear timeout
message instead of hanging the poll cycle indefinitely. C<timeout> is
optional and overrides the bound used for this call only (mainly for
tests); otherwise it's the injected/default C<ua>'s own C<timeout>, or
C<DEFAULT_HARD_TIMEOUT> if that can't be read.

C<dir> (TGT-051, typically C<D2TG::Config::attachments_dir>'s result) is
optional. When given, the file is named by its own content's SHA256
hash (plus the original extension) and written under C<dir> - if a file
with that exact hash already exists there, the download's HTTP request
still happens (the content has to be fetched to know its hash) but the
existing file's content is kept as-is and nothing is re-written, so
identical content downloaded any number of times only ever occupies one
copy of disk space. Its mtime, however, IS refreshed to now on every
such dedup hit (TGT-054) - a repeatedly re-sent file counts as freshly
used, so C<prune_vault>'s oldest-C<mtime>-first eviction (below) treats
it as recently active rather than as stale since its one-time original
download. Without C<dir>, behavior is unchanged from before TGT-051: a
uniquely-named file in the OS temp directory every call, never
deduplicated.

The first-time (non-dedup) write to a content-addressed path goes
through L</_atomic_write> (TGT-080, a real live-reproduced incident): a
process killed between finishing the write and the final rename leaves
I<no file at all> at the hash-derived path, never a truncated one - a
crash during a direct C<open/print/close> to that path used to leave
exactly that: a truncated file whose real content no longer matched
its own filename's claimed hash, silently trusted forever after since
the dedup check only tests C<-e>, never re-hashes.

C<download_file> uses L<D2TG::Config/_with_hard_timeout> (TGT-126;
extracted into D2TG::Config by TGT-173 after being found duplicated
byte-for-byte in L<D2TG::Telegram> too) to run its HTTP GET under an
C<alarm()>/C<SIGALRM>-based hard timeout - C<alarm()> reliably
interrupts any blocking syscall, including a stuck C<connect()>,
regardless of which phase it's stuck in, unlike C<LWP::UserAgent>'s
own C<timeout>. Dies with
C<"D2TG::Download::download_file: request timed out after ${seconds}s">
if the alarm fires, passing that exact string as the shared helper's
own die-message prefix, so the complete timeout wording is unchanged
from before the extraction; always clears the alarm before returning
or re-dying, on both the success and timeout paths.

=head2 _atomic_write($path, $content, after_write => \&coderef)

Writes C<$content> to a temp file in the same directory as C<$path>,
then C<rename>s it onto C<$path> - C<rename> is atomic on POSIX
filesystems, so any interruption before it runs leaves nothing at
C<$path>. C<after_write> is a test-only hook (same pattern as
C<run_once_safe>'s injectable C<sleep>), called after the temp file is
fully written and closed but before the rename - it exists so a test
can deterministically synchronize a real process kill to land exactly
between those two steps, instead of racing wall-clock timing against a
production write that has no such hook.

=head2 retry_failed_download($telegram, $store, $row, $dir, ua => $optional_client)

TGT-104: retries one L<D2TG::Store/failed_downloads> row - C<$row> is
one of the hashrefs that method returns (C<id>, C<chat_id>,
C<message_id>, C<file_id>, C<sender>, C<media_kind>, C<caption_note>,
C<error>). Returns C<(1, $local_path)> on success or C<(0, $error)> on
failure, mirroring L<D2TG::Poller>'s own C<_run_non_fatal> return shape.

On success, restores the message into C<$store>'s own history via
C<record_message> when C<$row> carries a C<media_kind> (the same
summary shape a first-time download success already builds - never the
real C<$local_path>, passed instead as C<record_message>'s own
C<local_path> argument, TGT-133), then removes the row via
C<remove_failed_download> - in that order, so a
crash between the two would at worst leave a harmless, already-restored
row still in the queue rather than a message nowhere at all. On failure,
the row is left untouched - never removed - so the caller (typically
C<cli/retry-download.pl>) can retry again later.

Both the C<record_message> and C<remove_failed_download> calls (TGT-194,
found via a scheduled JOB-003 hourly bug hunt, reproduced live in a
C<developer-dashboard:latest> container) are C<eval>-wrapped and
classified via C<D2TG::Poller::_classify_store_error> - a locked/busy
database at either one used to die raw, breaking this function's own
documented return contract even though the download itself genuinely
succeeded, and crashing C<cli/retry-download.pl>'s own per-row batch
loop mid-run since it has no C<eval> around this call either. A
bookkeeping-write failure is now logged non-fatally to STDERR as
C<STORE ERROR [chat_id]: ... failed - REASON> and does not affect the
reported C<(1, $local_path)> success.

=head2 prune_vault($dir, max_bytes => $bytes = 100MB)

Keeps the attachment vault (TGT-052, typically
C<D2TG::Config::attachments_dir>'s result) at or under C<max_bytes>
total: if the sum of every regular file's size in C<$dir> exceeds it,
deletes files oldest-C<mtime>-first until back at or under the cap.
A vault already at or under the cap is left completely untouched - not
even a listing beyond the size check. A non-existent or unreadable
C<$dir> is a silent no-op (nothing to prune). Since content-addressed
files (see C<download_file> above) are named by their own hash, deleting
an old copy here can never orphan a still-referenced summary pointing
at a different file - the same content, if downloaded again later,
simply gets re-fetched and re-written under its same hash-derived name.

=cut
