package Catmandu::Store::FedoraCommons;

use Catmandu::Sane;
use Catmandu::FedoraCommons;
use Moo;

with 'Catmandu::Store';

has baseurl  => (is => 'ro' , required => 1);
has username => (is => 'ro' , default => sub { '' } );
has password => (is => 'ro' , default => sub { '' } );
has model    => (is => 'ro' , default => sub { 'DC' } );

has fedora => (
    is       => 'ro',
    init_arg => undef,
    lazy     => 1,
    builder  => '_build_fedora',
);

sub _build_fedora {
    my $self = $_[0];
    
    Catmandu::FedoraCommons->new($self->baseurl, $self->username, $self->password);
}

package Catmandu::Store::FedoraCommons::Bag;

use Catmandu::Sane;
use Catmandu::Hits;
use Catmandu::Store::FedoraCommons::DC;
use Catmandu::Store::FedoraCommons::FOXML;
use Moo;
use Clone qw(clone);

with 'Catmandu::Bag';

sub _create_model {
    my ($self, $result) = @_;
    my $pid = $result->{pid};
    
    return undef unless $pid;
    
    my $model = $self->store->model;
    my $res   = $self->store->fedora->getDatastreamDissemination( pid => $pid , dsID => $model);
    
    return undef unless $res->is_ok;
    
    my $data  = $res->parse_content;
    my $perl  = Catmandu::Store::FedoraCommons::DC->new->deserialize($data);
    
    { _id => $pid , %$perl };
}

sub _update_model {
    my ($self, $data) = @_;
    my $pid = $data->{_id};

    return undef unless $pid;
    
    my $serializer = Catmandu::Store::FedoraCommons::DC->new;
    
    my ($valid,$reason) = $serializer->valid($data);
    
    unless ($valid) {
        warn "data is not valid";
        return undef;
    }
    
    my $xml    = $serializer->serialize($data);
    my $model  = $self->store->model;
    my $result = $self->store->fedora->modifyDatastream( pid => $pid , dsID => $model, xml => $xml);

    return $result->is_ok;
}

sub _ingest_model {
    my ($self, $data) = @_;
    
    my $serializer = Catmandu::Store::FedoraCommons::FOXML->new;
    
    my ($valid,$reason) = $serializer->valid($data);
    
    unless ($valid) {
        warn "data is not valid";
        return undef;
    }
    
    my $xml    = $serializer->serialize($data);
    
    my $result = $self->store->fedora->ingest( pid => 'new' , xml => $xml , format => 'info:fedora/fedora-system:FOXML-1.1');
    
    return undef unless $result->is_ok;
    
    $data->{_id} = $result->parse_content->{pid};
    
    return 1;
}

sub generator {
    my ($self) = @_;
    my $fedora = $self->store->fedora;
    
    sub {
        state $hits;
        state $row; 
        
        if( ! defined $hits) {
            my $res = $fedora->findObjects(terms=>'*');
            unless ($res->is_ok) {
                warn $res->error;
                return undef;
            }
            $row  = 0;
            $hits = $res->parse_content;
        }
        
        if ($row + 1 == @{ $hits->{results} } && defined $hits->{token}) {
            my $result = $hits->{results}->[ $row ];
            
            my $res = $fedora->findObjects(sessionToken => $hits->{token});
            
            unless ($res->is_ok) {
                warn $res->error;
                return undef;
            }
            
            $row  = 0;
            $hits = $res->parse_content;
            
            return $self->_create_model($result);
        }  
        else {
            my $result = $hits->{results}->[ $row++ ];
            return $self->_create_model($result);
        }
    };
}

sub add {
    my ($self,$data) = @_;    
    
    if (defined $self->get($data->{_id})) {
        my $ok = $self->_update_model($data);
        
        die "failed to update" unless $ok;
    }
    else {
        my $ok = $self->_ingest_model($data);
        
        die "failed to ingest" unless $ok;
    }
         
    return $data;
}

sub get {
    my ($self, $id) = @_;
    return $self->_create_model({ pid => $id });
}

sub delete {
    my ($self, $id) = @_;
    
    return undef if (!defined $id || $id =~ /^fedora-system:/) ;
    
    my $fedora = $self->store->fedora;
    
    $fedora->purgeObject(pid => $id)->is_ok;
}

sub delete_all {
    my ($self) = @_;
    
    my $count = 0;
    $self->each(sub {
        my $obj = $_[0];
        my $pid = $obj->{_id};
        
        return if $pid =~ /^fedora-system:/;
        
        my $ret = $self->delete($pid);
        
        $count += 1 if $ret->is_ok;
    });
    
    $count;
}

1;