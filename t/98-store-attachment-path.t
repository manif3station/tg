use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Store;

my ( undef, $db_path ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
my $store = D2TG::Store->new( db_path => $db_path, admin_chat_id => 1 );

is( $store->get_attachment_path( 999, 42 ), undef, 'no record yet: get_attachment_path returns undef' );

$store->record_message( 999, 42, 'ada', 'photo', local_path => '/secret/vault/abc123.jpg' );

my $got = $store->get_message( 999, 42 );
is( $got->{summary}, 'photo', 'summary text never contains the real path' );
unlike( $got->{summary}, qr{/secret}, 'summary carries no substring of the real path' );

is( $store->get_attachment_path( 999, 42 ), '/secret/vault/abc123.jpg', 'get_attachment_path returns the stored real path' );

$store->record_message( 999, 42, 'ada', 'photo (edited caption)' );
is( $store->get_attachment_path( 999, 42 ), '/secret/vault/abc123.jpg',
    're-recording the same message without a local_path preserves the previously stored one, not wipes it' );

$store->record_message( 999, 42, 'ada', 'photo (re-downloaded)', local_path => '/secret/vault/def456.jpg' );
is( $store->get_attachment_path( 999, 42 ), '/secret/vault/def456.jpg',
    're-recording with a new local_path overwrites the old one' );

is( $store->get_attachment_path( 999, 999 ), undef, 'a different message_id has no attachment path' );

done_testing();
