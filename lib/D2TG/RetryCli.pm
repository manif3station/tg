package D2TG::RetryCli;

use strict;
use warnings;
use D2TG::Config;
use D2TG::Poller::Safe;

# TGT-310 (found via a scheduled JOB-004 improvement hunt): cli/retry-
# download.pl and cli/retry-transcription.pl duplicated the identical
# argv-dispatch/retry-loop/reporting skeleton (a diff of the two files
# was 296 of ~480 total lines) - the same class of duplication
# D2TG::Store::RetryQueue.pm's own _record_failed/_list_failed/
# _due_for_retry helpers already fixed at the lib layer (TGT-295), just
# never applied to the CLI layer above it. Pure extraction, no behavior
# change - each caller's own flag-parsing preamble, Usage text, and POD
# stay in the script; only this shared skeleton moved. Full
# documentation lives in D2TG/RetryCli.pod (REQ-028: POD in a separate
# file).

sub _list_or_die {
    my (%args) = @_;

    my $result = eval { $args{list}->() };
    D2TG::Poller::Safe::die_store_error( $@, "failed_$args{label}s" ) if $@;
    return $result;
}

# run(%args): drives the whole list/dispatch/retry/report skeleton.
#
# Required: label ('download'|'transcription', for message text),
# list (coderef, no args, returns an arrayref of queued rows), argv
# (the remaining @ARGV after the caller's own flag-parsing preamble -
# either empty, '--all', or a single numeric id), telegram_builder
# (coderef, no args, returns a D2TG::Telegram instance - called AT MOST
# ONCE, and only once @to_retry is confirmed non-empty; both
# pre-extraction scripts never constructed D2TG::Telegram at all for a
# pure-listing invocation, since D2TG::Telegram->new dies without a
# token - a caller with no token configured could still list the queue
# before this extraction, and must still be able to after it), store,
# retry (coderef ($telegram, $store, $row) -> ($ok, $result_or_error,
# $still_queued)), format_success (coderef ($row, $result_or_error) ->
# the RETRY OK line's own trailing text, including its own leading
# separator punctuation and spacing - deliberately not hardcoded here,
# since the two pre-extraction scripts differ even in the separator
# itself: cli/retry-download.pl used " - GET ATTACHMENT WITH: ...",
# cli/retry-transcription.pl used ": <transcript>" with no dash at all.
# No leading "RETRY OK [id] chat_id=... message_id=..." and no
# trailing newline - run() supplies both of those itself).
#
# Exits the process directly (never returns) - matches both scripts'
# own pre-extraction behavior exactly.
sub run {
    my (%args) = @_;

    my $label          = $args{label};
    my @argv            = @{ $args{argv} };
    my $format_success = $args{format_success};

    if ( !@argv ) {
        my $queued = _list_or_die( list => $args{list}, label => $label );
        if ( !@$queued ) {
            print "No failed ${label}s queued.\n";
            exit 0;
        }
        for my $row (@$queued) {
            print "[$row->{id}] chat_id=$row->{chat_id} message_id=$row->{message_id} "
              . "file_id=$row->{file_id} error=\"$row->{error}\" queued_at=$row->{created_at}\n";
        }
        exit 0;
    }

    my @to_retry;
    if ( $argv[0] eq '--all' ) {
        @to_retry = @{ _list_or_die( list => $args{list}, label => $label ) };
        if ( !@to_retry ) {
            print "No failed ${label}s queued.\n";
            exit 0;
        }
    }
    else {
        my $id = $argv[0];
        my ($row) = grep { $_->{id} == $id } @{ _list_or_die( list => $args{list}, label => $label ) };
        if ( !$row ) {
            print STDERR "No queued failed $label with id $id.\n";
            exit 1;
        }
        @to_retry = ($row);
    }

    my $telegram = $args{telegram_builder}->();

    my $exit_code = 0;
    for my $row (@to_retry) {
        my ( $ok, $result_or_error, $still_queued ) = $args{retry}->( $telegram, $args{store}, $row );

        if ( !$ok ) {
            if ( D2TG::Config::is_expired_file_error($result_or_error) ) {
                print STDERR "RETRY EXPIRED [$row->{id}] chat_id=$row->{chat_id} message_id=$row->{message_id}: "
                  . "Telegram reports this file_id as permanently gone (not merely a transient failure) - $result_or_error\n";
            }
            else {
                print STDERR "RETRY FAILED [$row->{id}] chat_id=$row->{chat_id} message_id=$row->{message_id}: $result_or_error\n";
            }
            $exit_code = 1;
            next;
        }

        if ($still_queued) {
            print "RETRY PARTIAL [$row->{id}] chat_id=$row->{chat_id} message_id=$row->{message_id} - "
              . "$args{partial_note}; "
              . "the entry remains queued (still queued) and will be retried automatically, "
              . "or retry again with $args{retry_command_name} $row->{id}\n";
            $exit_code = 1;
            next;
        }

        print "RETRY OK [$row->{id}] chat_id=$row->{chat_id} message_id=$row->{message_id}"
          . $format_success->( $row, $result_or_error ) . "\n";
    }

    exit $exit_code;
}

1;
