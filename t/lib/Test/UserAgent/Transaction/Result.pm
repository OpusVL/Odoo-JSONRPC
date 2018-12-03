package Test::UserAgent::Transaction::Result;
use Moo;
has content => (
    is => 'ro'
);

sub json {
    return $_[0]->content
}
1;
