use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Reply;

# TGT-096 (live user request via Telegram): a transient send_reply
# failure (network timeout / 5xx) currently looks identical to a
# permanent one to the calling agent - no signal that retrying would
# likely succeed. format_send_error appends an explicit retry
# instruction for transient-shaped errors only.

for my $case (
    {
        label => 'a request-timeout error (D2TG::Telegram sendVoice)',
        error => "D2TG::Telegram sendVoice: HTTP request failed (status 500 D2TG::Telegram sendVoice: request timed out after 50s)\n",
        transient => 1,
    },
    {
        label => 'a bare "timed out" error',
        error => "D2TG::Telegram getMe: request timed out after 30s\n",
        transient => 1,
    },
    {
        label => 'a 502 Bad Gateway status',
        error => "D2TG::Telegram sendMessage: HTTP request failed (status 502 Bad Gateway)\n",
        transient => 1,
    },
    {
        label => 'a 503 Service Unavailable status',
        error => "D2TG::Telegram sendMessage: HTTP request failed (status 503 Service Unavailable)\n",
        transient => 1,
    },
    {
        label => 'a 401 Unauthorized (bad token) - not transient',
        error => "D2TG::Telegram sendMessage: HTTP request failed (status 401 Unauthorized)\n",
        transient => 0,
    },
    {
        label => 'a 400 Bad Request (invalid chat_id) - not transient',
        error => "D2TG::Telegram sendMessage: HTTP request failed (status 400 Bad Request)\n",
        transient => 0,
    },
)
{
    my $formatted = D2TG::Reply::format_send_error( $case->{error} );

    like( $formatted, qr/\Q$case->{error}\E/, "format_send_error preserves the original error text ($case->{label})" );

    if ( $case->{transient} ) {
        like( $formatted, qr/try (running|again)/i, "format_send_error adds a retry instruction for $case->{label}" );
    }
    else {
        unlike( $formatted, qr/try (running|again)/i, "format_send_error does NOT suggest retrying for $case->{label}" );
    }
}

done_testing();
