#!/usr/bin/env perl

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Spec;
use Time::Piece;

use D2TG::Config;
use D2TG::Config::Flags;
use D2TG::Poller::Safe;
use D2TG::Store;
use D2TG::Reply;
use D2TG::Reply::Args;

my ( $db_alias, @after_db );
( $db_alias, @after_db ) = D2TG::Config::Flags::extract_db_flag_or_die(@ARGV);
@ARGV = @after_db;

# TGT-233 (fast-follow from TGT-232's own scope decision): TGT-232 made
# D2TG::Store's messages table bot_key-aware, but this script had no
# --bot flag at all - matching cli/retry-download.pl's own established
# leading-position convention. TGT-236 centralized the eval-wrap idiom
# itself into D2TG::Reply::Args::extract_bot_flag_or_die.
my ( $bot_token, @after_bot ) = D2TG::Reply::Args::extract_bot_flag_or_die(@ARGV);
@ARGV = @after_bot;
my $bot_key = defined $bot_token ? $bot_token : '';

my ( $since, $until );
{
    my @rest;
    while (@ARGV) {
        my $arg = shift @ARGV;
        if ( $arg eq '--since' || $arg eq '--until' ) {
            my $value = eval { D2TG::Config::Flags::shift_flag_value( \@ARGV, $arg ) };
            if ($@) {
                print STDERR "d2 tg.history: $@";
                exit 2;
            }
            # TGT-209 (found via a scheduled JOB-003 hourly bug hunt,
            # reproduced live): a value that IS present but doesn't look
            # like a date at all used to be accepted with no shape check
            # at all and passed straight into
            # D2TG::Store::messages_in_range's own lexicographic SQL
            # comparison - a malformed value like "not-a-date" sorts
            # lexicographically AFTER every real ISO8601 timestamp, so a
            # ">=" comparison against it silently excludes every real
            # message, producing the exact same misleading "No messages
            # found." TGT-070 already fixed for the missing-value case,
            # but for a wrong-shaped value instead. Accepts both a
            # date-only value and a full ISO8601 date+time value (the
            # documented usage form), matching created_at's own stored
            # shape closely enough to catch real typos without rejecting
            # anything this command has ever documented as valid.
            if ( $value !~ /^\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}:\d{2})?$/ ) {
                print STDERR "d2 tg.history: $arg value '$value' is not a "
                  . "valid ISO8601 date (expected YYYY-MM-DD or "
                  . "YYYY-MM-DDTHH:MM:SS)\n";
                exit 2;
            }

            # TGT-302 (found via a user-requested comprehensive
            # bug/improvement sweep): the shape check above only
            # confirms the value LOOKS like a date - it never confirmed
            # the month/day combination is a real calendar date (e.g.
            # 2026-13-45, or 2026-02-29 in a non-leap year), so a
            # calendrically invalid value reached messages_in_range's
            # SQL comparison unvalidated. Time::Piece->strptime does
            # NOT reject an out-of-range day/month - it silently rolls
            # it forward (e.g. 2026-02-30 becomes 2026-03-02), so
            # round-trip the parsed value back to the same format and
            # compare against the original instead of trusting
            # strptime to die.
            my ($date_part) = $value =~ /^(\d{4}-\d{2}-\d{2})/;
            my $parsed = eval { Time::Piece->strptime( $date_part, '%Y-%m-%d' ) };
            if ( !$parsed || $parsed->ymd ne $date_part ) {
                print STDERR "d2 tg.history: $arg value '$value' is not a "
                  . "valid calendar date\n";
                exit 2;
            }

            # TGT-337 (found via a live, user-requested adversarial bug
            # hunt): the calendar-date check above only validates the
            # DATE part of a full date+time value - the time-of-day
            # component was never validated at all, so a syntactically
            # well-formed but impossible value like
            # 2026-01-01T99:99:99 reached messages_in_range's own
            # lexicographic SQL comparison unvalidated, silently
            # excluding every real message (the same misleading "No
            # messages found." bug class TGT-209/TGT-302 already fixed
            # for other malformed shapes). Unlike the date part, a
            # live probe confirmed Time::Piece's own %H:%M:%S parsing
            # genuinely DIES on an out-of-range hour/minute/second
            # (24:00:00, 12:60:00, 12:00:60 all die) rather than
            # silently rolling over the way the day/month component
            # does - so a bare eval-wrapped round-trip of the full
            # value is enough here, no string-comparison needed the
            # way the date-only check above needs it.
            if ( $value =~ /T(\d{2}:\d{2}:\d{2})$/ ) {
                my $time_ok = eval { Time::Piece->strptime( $value, '%Y-%m-%dT%H:%M:%S' ) };
                if ( !$time_ok ) {
                    print STDERR "d2 tg.history: $arg value '$value' is not a "
                      . "valid time of day\n";
                    exit 2;
                }
            }

            if ( $arg eq '--since' ) { $since = $value }
            else                     { $until = $value }
        }
        else {
            push @rest, $arg;
        }
    }
    @ARGV = @rest;
}

# TGT-122 (found via a scheduled hourly bug-hunt): an unrecognized flag
# or leftover positional argument used to be silently ignored here -
# unlike cli/send.pl's own @extra check or cli/poller.pl's unrecognized-
# argument refusal (TGT-107) - exiting 0 as if the (mistyped)
# invocation had succeeded (reproduced as printing "No messages
# found." when nothing happened to match, but a query that happened
# to match real history would have printed it instead).
if (@ARGV) {
    print STDERR "Usage: d2 tg.history [--bot <token>] [--since <iso8601>] [--until <iso8601>] [--db <alias> | -d <alias>]\n";
    exit 2;
}

# TGT-309 (found via a scheduled JOB-004 improvement hunt): resolving
# storage now runs AFTER all argv validation above (the --since/--until
# shape/calendar checks and this leftover-@ARGV check) - TGT-211 already
# fixed this exact ordering bug for attachment.pl/retry-download.pl/
# approve.pl, but missed this script. A caller with both a bad --db
# alias and malformed args must get exit 2/Usage: (or this script's own
# more specific --since/--until error, also exit 2), not exit 1/a
# storage-resolution error, matching every sibling command.
my $base_dir = D2TG::Config::resolve_and_require_base_dir_or_die( alias => $db_alias );

# TGT-186 (found via a scheduled JOB-003 hourly bug hunt, reproduced live):
# this call was unwrapped, the same raw-crash/db-path-leak risk TGT-183
# already fixed for cli/poller.pl's own equivalent call - not
# byte-identical args (poller.pl passes admin_chat_id as an arrayref of
# every configured group's chat_id; this script passes a plain scalar),
# but the same eval/classify/refuse shape. Now goes through the shared
# D2TG::Poller::Safe::open_store_or_die helper (TGT-186) - prints a clean,
# scrubbed refusal and exits 1 on a storage-open failure instead of
# letting the raw Perl/DBI exception (which can embed the real db path)
# propagate.
my $store = D2TG::Poller::Safe::open_store_or_die(
    skill_root    => File::Spec->catdir( $Bin, '..' ),
    base_dir      => $base_dir,
    admin_chat_id => D2TG::Config::chat_id(),
);

# TGT-293 (found via a user-requested comprehensive bug/improvement
# sweep): this call ran unwrapped - the same raw-crash/db-path-leak
# risk TGT-183/186/195 already fixed for other call sites in this
# project, just never swept this widely.
my @messages = eval {
    ( defined $since || defined $until )
      ? $store->messages_in_range( since => $since, until => $until, bot_key => $bot_key )
      : reverse $store->recent_messages( 10, bot_key => $bot_key );
};
D2TG::Poller::Safe::die_store_error( $@, 'history lookup' ) if $@;

if ( !@messages ) {
    print "No messages found.\n";
    exit 0;
}

for my $msg (@messages) {
    print "[$msg->{chat_id}] msg #$msg->{message_id} $msg->{sender} ($msg->{created_at}): $msg->{summary}\n";
}

=head1 NAME

history - view past messages by date range, dispatched as C<d2 tg.history>

=head1 SYNOPSIS

    d2 tg.history
    d2 tg.history --since 2026-09-01T00:00:00
    d2 tg.history --until 2026-09-07T23:59:59
    d2 tg.history --since 2026-09-01T00:00:00 --until 2026-09-07T23:59:59
    d2 tg.history --db <alias>
    d2 tg.history -d <alias>
    d2 tg.history --bot <token>

=head1 DESCRIPTION

C<--db <alias>>/C<-d <alias>> (TGT-051, or C<D2TG_DB=<alias>> as a
fallback) resolves the same way C<d2 tg.poller>'s does - see
L<D2TG::Config/resolve_alias_dir>. The resolved directory (or a
C<TIRA_HOME> fallback) must already exist - refuses to start otherwise
rather than creating it (TGT-090, see L<D2TG::Config/require_existing_base_dir>).

C<--bot <token>> (TGT-233) scopes the listing to that bot's own
messages, matching C<d2 tg.retry-download>'s established C<--bot>
convention; omitting it preserves the default-bot behavior below
unchanged.

Lists stored messages (TGT-038) oldest first: chat id, message id,
sender, timestamp, and the stored summary. Without C<--since>/C<--until>
(TGT-048), shows the 10 most recent messages. With either or both given
(ISO 8601 timestamps, matching C<created_at>'s own stored format), shows
every message in that range instead - an open-ended range on whichever
side is omitted. Prints C<No messages found.> and exits 0 when nothing
matches, rather than a blank/confusing output.

C<--since>/C<--until> validate their shifted value (TGT-070, a real
live-reproduced incident, same class of bug as TGT-069's
C<D2TG::Config::Flags::bot_groups> fix): a bare trailing flag with nothing
following it, or one immediately followed by the other flag (which
would otherwise silently swallow that flag's own name as the value),
exits 2 with a clear C<requires a value> message instead of silently
running the query unscoped or mis-scoped to match nothing. This
validation is delegated to L<D2TG::Config::Flags/shift_flag_value> (TGT-072),
shared with C<--db>/C<-d>'s own validation and C<D2TG::Config::Flags::bot_groups>'s
C<--chat_id> validation.

C<--since>/C<--until> also validate the *shape* of their value (TGT-209,
found via a scheduled hourly bug-hunt): a value that doesn't match
C<YYYY-MM-DD> or C<YYYY-MM-DDTHH:MM:SS> exits 2 with a message naming the
malformed value and the expected format, instead of being passed
straight into L<D2TG::Store/messages_in_range>'s own SQL comparison,
where a value like C<not-a-date> sorts lexicographically after every
real timestamp and silently excludes every message - the same
misleading C<No messages found.> outcome TGT-070 fixed for a missing
value, but for a wrong-shaped one.

C<--since>/C<--until> also validate the value is a real *calendar*
date, not merely date-shaped (TGT-302, found via a user-requested
comprehensive bug/improvement sweep): the shape check above accepts a
syntactically well-formed but nonexistent date like C<2026-13-45> or
C<2026-02-30> (or a non-leap-year C<2026-02-29>) - round-tripping the
value through core L<Time::Piece> (which silently rolls an
out-of-range date forward rather than dying, so the parsed result is
compared back against the original) and refusing on a mismatch closes
that gap.

Any other unrecognized flag or leftover positional argument also exits
2 with a C<Usage:> message (TGT-122, found via a scheduled hourly
bug-hunt) - previously silently ignored, exiting 0 as if the
(mistyped) invocation had succeeded (reproduced as printing C<No
messages found.> when nothing happened to match, but a query that
happened to match real history would have printed it instead), unlike
C<cli/send.pl>'s own C<@extra> check or C<cli/poller.pl>'s
unrecognized-argument refusal (TGT-107).

The message lookup itself (TGT-293, found via a user-requested
comprehensive bug/improvement sweep) is C<eval>-wrapped and classified
via C<D2TG::Poller::Safe::classify_store_error> - a locked/busy database
at that call used to die raw, printing a raw Perl/DBI exception
(potentially embedding the real db_path) to STDERR instead of a clean
C<STORE ERROR: ... failed - REASON> refusal.

Storage resolution (the C<--db>/C<-d> block above) now runs AFTER all
of this script's own argv validation - the C<--since>/C<--until>
shape/calendar checks and the leftover-argument check (TGT-309, found
via a scheduled JOB-004 improvement hunt). TGT-211 already established
this ordering for C<cli/attachment.pl>/C<cli/retry-download.pl>/
C<cli/approve.pl>; this script was the same minority-family bug, just
missed from that sweep. A caller supplying both a bad C<--db> alias
and malformed args now gets exit 2 (C<Usage:> or one of this script's
own specific date-validation messages, also exit 2), never exit 1 from
a storage-resolution error - matching every sibling C<d2 tg.*> command.

=cut
