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

if ( @ARGV != 2 || $ARGV[0] !~ /^-?\d+$/ || $ARGV[1] !~ /^\d+$/ ) {
    print STDERR "Usage: d2 tg.attachment <chat_id> <message_id> [--db <alias> | -d <alias>]\n";
    exit 2;
}
my ( $chat_id, $message_id ) = @ARGV;

my $store = D2TG::Store->new(
    db_path => D2TG::Config::state_db_path(
        default_root => File::Spec->catdir( $Bin, '..' ),
        base_dir      => $base_dir,
    ),
    admin_chat_id => D2TG::Config::chat_id(),
);

my $local_path = $store->get_attachment_path( $chat_id, $message_id );
if ( !defined $local_path ) {
    print STDERR "d2 tg.attachment: no attachment recorded for chat $chat_id message $message_id\n";
    exit 1;
}

open my $fh, '<', $local_path
  or do {
    print STDERR "d2 tg.attachment: cannot open the stored attachment: $!\n";
    exit 1;
  };
binmode $fh;
binmode STDOUT;
local $/;
print scalar <$fh>;
close $fh;

exit 0;

=head1 NAME

attachment - stream a downloaded attachment's raw bytes to stdout, dispatched as C<d2 tg.attachment>

=head1 SYNOPSIS

    d2 tg.attachment <chat_id> <message_id> [--db <alias> | -d <alias>]

=head1 DESCRIPTION

C<--db <alias>>/C<-d <alias>> (TGT-051, or C<D2TG_DB=<alias>> as a
fallback) resolves the same way C<d2 tg.poller>'s does - see
L<D2TG::Config/resolve_alias_dir>. The resolved directory (or a
C<TIRA_HOME> fallback) must already exist - refuses to start otherwise
rather than creating it (TGT-090).

TGT-133: looks up C<local_path> for the given C<(chat_id, message_id)>
pair via L<D2TG::Store/get_attachment_path> and writes its raw bytes
to stdout - the real on-disk path is never printed anywhere, matching
this project's own Tira board convention (C<tira.attachment.get>).
Refuses (exit 1, clear STDERR message) if no attachment is recorded for
that pair, or if the stored path can no longer be opened. C<chat_id>
and C<message_id> must both be given and numeric (exit 2, Usage
message, otherwise) - C<chat_id> may be negative (a Telegram group/
channel id).

=cut
