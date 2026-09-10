#!/usr/bin/env perl

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Spec;

use D2TG::Config;
use D2TG::Store;

my ( $db_alias, @after_db );
eval { ( $db_alias, @after_db ) = D2TG::Config::extract_db_flag(@ARGV) };
if ($@) {
    print STDERR $@;
    exit 1;
}
@ARGV = @after_db;

my $base_dir = D2TG::Config::resolve_alias_dir_or_die( alias => $db_alias );

eval { D2TG::Config::require_existing_base_dir($base_dir) };
if ($@) {
    print STDERR $@;
    exit 1;
}

my ( $since, $until );
{
    my @rest;
    while (@ARGV) {
        my $arg = shift @ARGV;
        if ( $arg eq '--since' || $arg eq '--until' ) {
            my $value = eval { D2TG::Config::shift_flag_value( \@ARGV, $arg ) };
            if ($@) {
                print STDERR "d2 tg.history: $@";
                exit 2;
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
    print STDERR "Usage: d2 tg.history [--since <iso8601>] [--until <iso8601>] [--db <alias> | -d <alias>]\n";
    exit 2;
}

my $store = D2TG::Store->new(
    db_path => D2TG::Config::state_db_path(
        default_root => File::Spec->catdir( $Bin, '..' ),
        base_dir      => $base_dir,
    ),
    admin_chat_id => D2TG::Config::chat_id(),
);

my @messages =
  ( defined $since || defined $until )
  ? $store->messages_in_range( since => $since, until => $until )
  : reverse $store->recent_messages(10);

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

=head1 DESCRIPTION

C<--db <alias>>/C<-d <alias>> (TGT-051, or C<D2TG_DB=<alias>> as a
fallback) resolves the same way C<d2 tg.poller>'s does - see
L<D2TG::Config/resolve_alias_dir>. The resolved directory (or a
C<TIRA_HOME> fallback) must already exist - refuses to start otherwise
rather than creating it (TGT-090, see L<D2TG::Config/require_existing_base_dir>).

Lists stored messages (TGT-038) oldest first: chat id, message id,
sender, timestamp, and the stored summary. Without C<--since>/C<--until>
(TGT-048), shows the 10 most recent messages. With either or both given
(ISO 8601 timestamps, matching C<created_at>'s own stored format), shows
every message in that range instead - an open-ended range on whichever
side is omitted. Prints C<No messages found.> and exits 0 when nothing
matches, rather than a blank/confusing output.

C<--since>/C<--until> validate their shifted value (TGT-070, a real
live-reproduced incident, same class of bug as TGT-069's
C<D2TG::Config::bot_groups> fix): a bare trailing flag with nothing
following it, or one immediately followed by the other flag (which
would otherwise silently swallow that flag's own name as the value),
exits 2 with a clear C<requires a value> message instead of silently
running the query unscoped or mis-scoped to match nothing. This
validation is delegated to L<D2TG::Config/shift_flag_value> (TGT-072),
shared with C<--db>/C<-d>'s own validation and C<D2TG::Config::bot_groups>'s
C<--chat_id> validation.

Any other unrecognized flag or leftover positional argument also exits
2 with a C<Usage:> message (TGT-122, found via a scheduled hourly
bug-hunt) - previously silently ignored, exiting 0 as if the
(mistyped) invocation had succeeded (reproduced as printing C<No
messages found.> when nothing happened to match, but a query that
happened to match real history would have printed it instead), unlike
C<cli/send.pl>'s own C<@extra> check or C<cli/poller.pl>'s
unrecognized-argument refusal (TGT-107).

=cut
