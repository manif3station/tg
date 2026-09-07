use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Store;

my ( undef, $db_path ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
my $store = D2TG::Store->new( db_path => $db_path, admin_chat_id => 1 );

is( $store->get_message( 999, 42 ), undef, 'no record yet: get_message returns undef' );

$store->record_message( 999, 42, 'ada', 'hello there' );
my $got = $store->get_message( 999, 42 );
is( $got->{sender},  'ada',         'record_message: sender stored' );
is( $got->{summary}, 'hello there', 'record_message: summary stored' );

$store->record_message( 999, 42, 'ada', 'hello there (edited)' );
my $updated = $store->get_message( 999, 42 );
is( $updated->{summary}, 'hello there (edited)', 'record_message: re-recording the same chat_id+message_id overwrites the summary' );

is( $store->get_message( 999, 43 ), undef, 'a different message_id in the same chat is still unrecorded' );
is( $store->get_message( 1000, 42 ), undef, 'the same message_id in a different chat is still unrecorded' );

done_testing();
