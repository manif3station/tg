#!/usr/bin/env perl

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Spec;

use D2TG::Config;
use D2TG::Store;

my ( $db_alias, @rest );
eval { ( $db_alias, @rest ) = D2TG::Config::extract_db_flag(@ARGV) };
if ($@) {
    print STDERR $@;
    exit 1;
}
@ARGV = @rest;

# TGT-149 (found via a scheduled hourly bug-hunt): every sibling
# command in this exact family (cli/status.pl, cli/history.pl -
# TGT-122, cli/whoami.pl, cli/text-only-replies.pl) already refuses an
# unrecognized flag or leftover positional argument instead of
# silently ignoring it - this command was the one missing it.
if (@ARGV) {
    print STDERR "Usage: d2 tg.unread [--db <alias> | -d <alias>]\n";
    exit 2;
}

my $base_dir = D2TG::Config::resolve_alias_dir_or_die( alias => $db_alias );

eval { D2TG::Config::require_existing_base_dir($base_dir) };
if ($@) {
    print STDERR $@;
    exit 1;
}

my $store = D2TG::Store->new(
    db_path => D2TG::Config::state_db_path(
        default_root => File::Spec->catdir( $Bin, '..' ),
        base_dir      => $base_dir,
    ),
    admin_chat_id => D2TG::Config::chat_id(),
);

my @unread = $store->unread_messages;

if ( !@unread ) {
    print "No unread messages.\n";
    exit 0;
}

for my $msg (@unread) {
    print "[$msg->{chat_id}] msg #$msg->{message_id} $msg->{sender} ($msg->{created_at}): $msg->{summary}\n";
}

=head1 NAME

unread - list new/non-replied messages, dispatched as C<d2 tg.unread>

=head1 SYNOPSIS

    d2 tg.unread [--db <alias> | -d <alias>]

=head1 DESCRIPTION

C<--db <alias>>/C<-d <alias>> (TGT-051, or C<D2TG_DB=<alias>> as a
fallback) resolves the same way C<d2 tg.poller>'s does - see
L<D2TG::Config/resolve_alias_dir>. The resolved directory (or a
C<TIRA_HOME> fallback) must already exist - refuses to start otherwise
rather than creating it (TGT-090, see L<D2TG::Config/require_existing_base_dir>).

Lists every message L<D2TG::Store> has recorded (TGT-038) that has not
been marked read (TGT-046, via a successful C<d2 tg.reply
--reply-to-message-id>), oldest first: chat id, message id, sender,
timestamp, and the stored summary. Prints C<No unread messages.> and
exits 0 when there are none, rather than an empty/confusing output.

Refuses with a C<Usage:> message and exit code 2 on any unrecognized
flag or leftover positional argument (TGT-149, found via a scheduled
bug-hunt) - matching every sibling command in this same family
(C<cli/status.pl>, C<cli/history.pl> per TGT-122, C<cli/whoami.pl>,
C<cli/text-only-replies.pl>), all of which already refused rather than
silently ignoring one.

=cut
