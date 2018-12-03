package Test::UserAgent;
use Moo;
use JSON::MaybeXS;
use Test::UserAgent::Transaction;
use Test::UserAgent::Transaction::Result;

sub post {
    my $self = shift;

    Test::UserAgent::Transaction->new(
        result => Test::UserAgent::Transaction::Result->new(
            content => $self->fake_post_response(@_)
        )
    );
}

sub fake_post_response {
    my $self = shift;
    my $url = shift;
    my $data = shift;

    my $href = decode_json($data);

    if ($url =~ m{/web/session/authenticate}) {
        # only uid is really needed for the lib to consider it a success
        if ($href->{params}->{login} eq 'admin'
        and $href->{params}->{password} eq 'admin') {
            return {
                id => 0,
                jsonrpc => "2.0",
                result => {
                    uid => 1,
                    name => "Administrator",
                    username => 'admin'
                }
            }
        }
        else {
            #return fake error
            return {
                id => 0,
                jsonrpc => "2.0",
                result => {
                    uid => 0,
                    name => "",
                    username => ''
                }
            }
        }
        elsif ($url =~ m{/web/dataset/call_kw}) {
            return {
                id => 0,
                jsonrpc => "2.0",
                result => [
                    { id => 3, name => "CC.AX.DNA SO003" },
                    { id => 5, name => "CC.AX.DNA SO005" },
                ]
            }
        }
    }
}
1;
