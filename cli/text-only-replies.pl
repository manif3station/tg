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

if (@ARGV) {
    print STDERR "Usage: d2 tg.text-only-replies [--db <alias> | -d <alias>]\n";
    exit 2;
}

my $base_dir = eval { D2TG::Config::resolve_alias_dir( alias => $db_alias ) };
if ($@) {
    print STDERR $@;
    exit 1;
}

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

my $flagged = $store->text_only_replies;

if ( !@$flagged ) {
    print "No text-only replies found.\n";
    exit 0;
}

for my $row (@$flagged) {
    print "[chat_id=$row->{chat_id}] msg #$row->{text_message_id} sent ($row->{created_at}) "
      . "went out text-only - no voice note ever confirmed sent.\n";
}

exit 1;

=head1 NAME

text-only-replies - list any reply that went out as text-only, dispatched as C<d2 tg.text-only-replies>

=head1 SYNOPSIS

    d2 tg.text-only-replies [--db <alias> | -d <alias>]

=head1 DESCRIPTION

TGT-105 (user-supplied feature-gap analysis): TGT-083 deliberately
reordered L<D2TG::Reply/send_reply> to send text first, then
synthesize+send voice - a synthesis or C<send_voice> failure after that
point can leave a reply text-only, always reported loudly (non-zero
exit) at the moment it happens, per that ticket's own documented
tradeoff. If that loud failure is missed (the agent wasn't watching, the
error scrolled past), there was previously no way to find out later.

C<D2TG::Reply::send_reply> now records every text send via
L<D2TG::Store/record_sent_text> immediately after it succeeds, and
records the matching voice send via L<D2TG::Store/record_sent_voice>
once that also succeeds; a row still missing its voice half IS the
text-only condition (no separate boolean flag to fall out of sync).
C<D2TG::Reply::resend_voice> (TGT-109's own recovery path) clears the
flag the same way when a voice recovery succeeds.

Lists every currently-flagged reply - chat_id, the text message's own
id, and when it was sent - or C<No text-only replies found.> when clean.
Exits 1 when anything is flagged (0 when clean), matching this
project's other after-the-fact checker conventions, so this command is
suitable for a periodic scheduled check rather than only manual
inspection. C<--db>/C<-d> (or C<D2TG_DB>) resolves exactly as every
other C<d2 tg.*> command's does.

=cut
