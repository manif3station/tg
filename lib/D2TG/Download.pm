package D2TG::Download;

use strict;
use warnings;
use LWP::UserAgent;
use File::Temp qw(tempfile);
use File::Spec;
use Digest::SHA qw(sha256_hex);
use D2TG::Config;
use D2TG::Poller::Safe;

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

    # TGT-196 (Michael's own design choice, Q-013, closing a Codex
    # documentation-stage review finding on TGT-194's own fix): a
    # persistently-failing record_message used to re-download the same
    # already-fetched file on every retry pass, forever, with no escape
    # hatch. A row whose own local_path is already set (persisted by a
    # PRIOR retry that downloaded successfully but then failed on
    # record_message - see below) means the download half is already
    # done; skip it entirely and go straight to retrying only the
    # record_message write against that already-downloaded file.
    my $local_path;
    if ( defined $row->{local_path} ) {
        $local_path = $row->{local_path};
    }
    else {
        $local_path = eval { download_file( $telegram, $row->{file_id}, dir => $dir, ua => $args{ua} ) };

        if ($@) {
            my $error = $@;
            $error =~ s/\n\z//;
            return ( 0, $error );
        }
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
    # eval-wrapped and classified via D2TG::Poller::Safe::classify_store_error,
    # matching the established pattern - a bookkeeping-write failure is
    # logged non-fatally to STDERR and does not affect the reported
    # (1, $local_path) success, since the download itself did succeed.
    # A Codex documentation-stage review finding: removing the queue
    # row unconditionally, even when record_message itself failed,
    # would be a genuine data-retention regression - the pre-fix code
    # accidentally preserved the row in this exact case (the raw die
    # from record_message happened BEFORE remove_failed_download was
    # ever reached, so a locked-database failure here at least left
    # the row queued for a later retry attempt). Silently removing it
    # anyway would leave a message with NEITHER a queue row NOR a
    # history record - worse than the pre-fix crash, not better. Only
    # remove the row when record_message either succeeded or was never
    # attempted (no media_kind); when it failed, the row stays queued
    # so a future retry can still restore history, and remove_failed_download
    # is deliberately not attempted at all this cycle.
    # A Codex QA-stage review finding: this pre-existing (unchanged by
    # TGT-194) `defined` guard - rather than a non-empty check - relies
    # on media_kind never being an empty string, only a real kind or
    # undef. Confirmed true: the only real caller populating this field
    # is D2TG::Poller::run_once, via record_failed_download's own
    # media_kind argument, which is always _media_kind($message)'s own
    # return value - that function's own contract (see its POD) returns
    # either a real non-empty kind string ('photo'/'document'/'voice'/
    # 'video') or undef, never ''. No other code path ever writes this
    # column, so an empty-string media_kind is unreachable through this
    # codebase's own actual data flow, not merely untested.
    # TGT-198: all 3 of this function's own eval/classify/print
    # blocks are promoted to the shared D2TG::Poller::Safe::store_write_safe
    # helper - none of these call sites need the coderef's own return
    # value, so only the \$ok half of the (\$ok, \$value) pair is used.
    my $record_ok = 1;
    if ( defined $row->{media_kind} ) {
        # TGT-133: the summary text (shown verbatim by cli/history.pl and
        # cli/unread.pl) must never contain the real local path - only
        # local_path (a separate, narrow-accessor-only column) does.
        my $summary = "$row->{media_kind}" . ( $row->{caption_note} // '' );
        # TGT-245 (found via a scheduled JOB-003 hourly bug hunt):
        # TGT-232 made the messages table bot_key-aware and threaded
        # bot_key through every record_message call site it enumerated -
        # this one was missed. $row->{bot_key} is already the exact
        # value this queue row was recorded under (TGT-219); without it,
        # record_message defaults to D2TG::Store::DEFAULT_BOT_KEY, so a
        # retried message in a multi-bot config silently lands under the
        # wrong bot's history instead of the one that actually received it.
        ($record_ok) = D2TG::Poller::Safe::store_write_safe(
            $row->{chat_id}, 'record_message',
            sub {
                $store->record_message(
                    $row->{chat_id}, $row->{message_id}, $row->{sender}, $summary,
                    local_path => $local_path, bot_key => $row->{bot_key},
                );
            }
        );
    }

    my $still_queued;
    if ($record_ok) {

        # TGT-249 (found via a scheduled JOB-003 hourly bug hunt): the
        # removal write itself is store_write_safe-wrapped for the same
        # reason record_message is - a locked/busy database can make it
        # fail transiently too. Its own (ok, value) result must be
        # inspected, not discarded - a still-queued row (removal write
        # failed) must never be reported as $still_queued=0, or
        # cli/retry-download.pl prints an unqualified RETRY OK for a row
        # that is, in fact, still sitting in failed_downloads.
        my ($remove_ok) =
          D2TG::Poller::Safe::store_write_safe( $row->{chat_id}, 'remove_failed_download', sub { $store->remove_failed_download( $row->{id} ) } );
        $still_queued = $remove_ok ? 0 : 1;
    }
    else {
        # TGT-196: persist the already-downloaded path on the row (a
        # no-op if a prior retry already did this for the same row) so
        # the NEXT retry attempt sees it via $row->{local_path} above
        # and skips download_file entirely - only the still-failing
        # record_message write is retried, not the whole download.
        D2TG::Poller::Safe::store_write_safe( $row->{chat_id}, 'mark_failed_download_downloaded', sub { $store->mark_failed_download_downloaded( $row->{id}, $local_path ) } );
        print STDERR "STORE ERROR [$row->{chat_id}]: queue row not removed - "
          . "a future retry can still restore history for this message, without re-downloading\n";
        $still_queued = 1;
    }

    # TGT-244 (found via a scheduled JOB-003 hourly bug hunt): the third
    # return value tells the caller whether the row is still sitting in
    # the queue after this attempt, independent of whether the download
    # itself succeeded - $ok alone conflated "download succeeded" with
    # "the whole retry attempt is fully done", which let
    # auto_retry_failed_downloads' 60s throttle be silently bypassed
    # whenever record_message kept failing after a successful download
    # (TGT-196's own documented "persistently-failing record_message"
    # scenario). A caller that only cares about the (ok, value) pair
    # (e.g. cli/retry-download.pl's manual path) is unaffected - this is
    # purely additive.
    return ( 1, $local_path, $still_queued );
}

# TGT-221 (Q-015 answered by Michael, 2026-09-14: retry every 60s for
# up to 5 minutes total, independent of poll cadence): TGT-204 made a
# queued failed_downloads row visible but explicitly deferred automatic
# recovery - it sat queued until a human/agent ran d2 tg.retry-download
# by hand. Called once per (chat_id group, bot) pair per poll cycle
# from cli/poller.pl's main loop, scoped to that pair's own bot_key
# (a retry needs the matching bot's own $telegram, since Telegram's
# file_id values are bot-token-scoped). Reuses retry_failed_download
# itself for the actual retry - only the "which rows, how often"
# selection logic is new (D2TG::Store::failed_downloads_due_for_retry).
# A row past the 5-minute window is silently skipped, not deleted - it
# stays fully visible/retryable via d2 tg.unread/d2 tg.retry-download
# exactly as before; this is additive automatic recovery, not a
# replacement for the manual escape hatch. Never dies - a locked/busy
# database or a retry failure must not turn this non-essential
# housekeeping into a poll-cycle failure, matching prune_vault/
# prune_history's own established non-fatal call-site pattern.
sub auto_retry_failed_downloads {
    my ( $telegram, $store, $dir, %args ) = @_;

    my $due = $store->failed_downloads_due_for_retry(
        defined $args{bot_key} ? ( bot_key => $args{bot_key} ) : ()
    );

    for my $row (@$due) {
        my ( $ok, $result_or_error, $still_queued ) = retry_failed_download( $telegram, $store, $row, $dir, ua => $args{ua} );

        # TGT-244: stamp last_retry_at whenever this attempt leaves the
        # row still in the queue - not only when the download step
        # itself failed ($ok false). A download that succeeded but whose
        # record_message write kept failing (TGT-196's own documented
        # scenario) left the row queued too, and must be throttled by
        # the same 60s interval, or failed_downloads_due_for_retry's own
        # "last_retry_at IS NULL" clause keeps matching it on every poll
        # cycle forever.
        if ( !$ok || $still_queued ) {
            eval { $store->mark_failed_download_retried( $row->{id} ) };
        }
    }

    return;
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
