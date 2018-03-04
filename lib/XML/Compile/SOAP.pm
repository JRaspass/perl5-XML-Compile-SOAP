use warnings;
use strict;

package XML::Compile::SOAP;

use Log::Report 'xml-compile-soap', syntax => 'SHORT';
use XML::Compile         ();
use XML::Compile::Util   qw/pack_type unpack_type type_of_node/;
use XML::Compile::Cache  ();
use XML::Compile::SOAP::Util qw/:xop10/;

use Time::HiRes          qw/time/;
use MIME::Base64         qw/decode_base64/;

=chapter NAME
XML::Compile::SOAP - base-class for SOAP implementations

=chapter SYNOPSIS
 ** SOAP1.1 and WSDL1.1 over HTTP

 # !!! The next steps are only required when you do not have
 # !!! a WSDL. See XML::Compile::WSDL11 if you have a WSDL.
 # !!! Without WSDL file, you need to do a lot manually

 use XML::Compile::SOAP11::Client;
 my $client = XML::Compile::SOAP11::Client->new;
 $client->schemas->importDefinitions(...);

 use XML::Compile::Util qw/pack_type/;
 my $h1el = pack_type $myns, $some_element;
 my $b1el = "{$myns}$other_element";  # same, less clean

 my $encode_query = $client->compileMessage
   ( 'SENDER'
   , style    => 'document'           # default
   , header   => [ h1 => $h1el ]
   , body     => [ b1 => $b1el ]
   , destination    => [ h1 => 'NEXT' ]
   , mustUnderstand => 'h1'
   );

 my $decode_response = $client->compileMessage
   ( 'RECEIVER'
   , header   => [ h2 => $h2el ]
   , body     => [ b2 => $b2el ]
   , faults   => [ ... ]
   );

 my $http = XML::Compile::Transport::SOAPHTTP
    ->new(address => $server);
 my $http = $transport->compileClient(action => ...);

 my @query    = (h1 => ..., b1 => ...);
 my $request  = $encode_query->(@query);
 my ($response, $trace) = $http->($request);
 my $answer   = $decode_response->($response);

 use Data::Dumper;
 warn Dumper $answer;     # discover a HASH with h2 and b2!

 if($answer->{Fault}) ... # when an error was reported

 # Simplify your life: combine above into one call
 # Also in this case: if you have a WSDL, this is created
 # for you.   $wsdl->compileClient('MyFirstCall');

 my $call   = $client->compileClient
   ( kind      => 'request-response'  # default
   , name      => 'MyFirstCall'
   , encode    => $encode_query
   , decode    => $decode_response
   , transport => $http
   );

 # !!! Usage, with or without WSDL file the same

 my $result = $call->(@quey)           # SCALAR only the result
 print $result->{h2}->{...};
 print $result->{b2}->{...};

 my ($result, $trace) = $call->(...);  # LIST will show trace
 # $trace is an XML::Compile::SOAP::Trace object

=chapter DESCRIPTION

This module handles the SOAP protocol.  The first implementation is
SOAP1.1 (F<http://www.w3.org/TR/2000/NOTE-SOAP-20000508/>), which is still
most often used.  The SOAP1.2 definition (F<http://www.w3.org/TR/soap12/>)
is quite different; this module tries to define a sufficiently abstract
interface to hide the protocol differences.

Be aware that there are three kinds of SOAP:

=over 4
=item 1.
Document style (literal) SOAP, where there is a WSDL file which explicitly
types all out-going and incoming messages.  Very easy to use.

=item 2.
RPC style SOAP literal.  The body of the message has an extra element
wrapper, but the content is also well defined.

=item 3.
RPC style SOAP encoded.  The sent data is nowhere described formally.
The data is constructed in some ad-hoc way.
=back

Don't forget to have a look at the examples in the F<examples/> directory
included in the distribution.

=chapter METHODS

=section Constructors

=method new OPTIONS
Create a new SOAP object.  You have to instantiate either the SOAP11 or
SOAP12 sub-class of this, because there are quite some differences (which
can be hidden for you)

=option  media_type MIMETYPE
=default media_type C<application/soap+xml>

=option  schemas    C<XML::Compile::Cache> object
=default schemas    created internally
Use this when you have already processed some schema definitions.  Otherwise,
you can add schemas later with C<< $soap->schemas->importDefinitions() >>
The Cache object must have C<any_element> and C<any_attribute> set to
C<'ATTEMPT'>

=cut

sub new($@)
{   my $class = shift;

    error __x"you can only instantiate sub-classes of {class}"
        if $class eq __PACKAGE__;

    (bless {}, $class)->init( {@_} );
}

sub init($)
{   my ($self, $args) = @_;
    $self->{mimens}  = $args->{media_type} || 'application/soap+xml';

    my $schemas = $self->{schemas} = $args->{schemas}
        || XML::Compile::Cache->new(allow_undeclared => 1
            , any_element => 'ATTEMPT', any_attribute => 'ATTEMPT');
    UNIVERSAL::isa($schemas, 'XML::Compile::Cache')
        or panic "schemas must be a Cache object";

    $self;
}

=section Accessors
=method name
=method version
=cut

sub name()    {shift->{name}}
sub version() {panic "not implemented"}

=method schemas
Returns the M<XML::Compile::Cache> object which contains the
knowledge about the types.
=cut

sub schemas() {shift->{schemas}}

#--------------------

=section Single message

=method compileMessage ('SENDER'|'RECEIVER'), OPTIONS
The payload is defined explicitly, where all headers and bodies are
described in detail.  When you have a WSDL file, these ENTRIES are
generated automatically, but can be modified and extended (WSDL files
are often incomplete)

To make your life easy, the ENTRIES use a label (a free to choose key,
the I<part name> in WSDL terminology), to ease relation of your data with
the type where it belongs to.  The element of an entry (the value) is
defined as an C<any> element in the schema, and therefore you will need
to explicitly specify the element to be processed.

As OPTIONS, you can specify any listed here, but also anything which is
accepted by M<XML::Compile::Schema::compile()>, like
C<< sloppy_integers => 1 >> and hooks.  These are applied to all header
and body elements (not to the SOAP wrappers)

=option  header ENTRIES|HASH
=default header C<undef>
ARRAY of PAIRS, defining a nice LABEL (free of choice but unique)
and an element type name.  The LABEL will appear in the Perl HASH, to
refer to the element in a simple way.

The element type is used to construct a reader or writer.  You may also
create your own reader or writer, and then pass a compatible CODE reference.

=option  body   ENTRIES|HASH
=default body   []
ARRAY of PAIRS, defining a nice LABEL (free of choice but unique, also
w.r.t. the header and fault ENTRIES) and an element type name or CODE
reference.  The LABEL will appear in the Perl HASH only, to be able to
refer to a body element in a simple way.

=option  faults ENTRIES|HASH
=default faults []
The SOAP1.1 and SOAP1.2 protocols define fault entries in the
answer.  Both have a location to add your own additional
information: the type(-processor) is to specified here, but the
returned information structure is larger and differs per SOAP
implementation.

=option  mustUnderstand STRING|ARRAY-OF-STRING
=default mustUnderstand []
Writers only.  The specified header entry labels specify which elements
must be understood by the destination.  These elements will get the
C<mustUnderstand> attribute set to C<1> (soap1.1) or C<true> (soap1.2).

=option  destination ARRAY-OF-PAIRS
=default destination []
Writers only.  Indicate who the target of the header entry is.
By default, the end-point is the destination of each header element.

The ARRAY contains a LIST of key-value pairs, specifing an entry label
followed by an I<actor> (soap1.1) or I<role> (soap1.2) URI.  You may use
the predefined actors/roles, like 'NEXT'.  See M<roleURI()> and
M<roleAbbreviation()>.

=option  role URI|ARRAY-OF-URI
=default role C<ULTIMATE>
Readers only.
One or more URIs, specifying the role(s) you application has in the
process.  Only when your role contains C<ULTIMATE>, the body is
parsed.  Otherwise, the body is returned as uninterpreted XML tree.
You should not use the role C<NEXT>, because every intermediate
node is a C<NEXT>.

All understood headers are parsed when the C<actor> (soap1.1) or
C<role> (soap1.2) attribute address the specified URI.  When other
headers emerge which are not understood but carry the C<mustUnderstood>
attribute, an fault is returned automatically.  In that case, the
call to the compiled subroutine will return C<undef>.

=option  roles ARRAY-OF-URI
=default roles []
Alternative for option C<role>

=cut

sub compileMessage($@)
{   my ($self, $direction, %args) = @_;
    $args{style} ||= 'document';

      $direction eq 'SENDER'   ? $self->_sender(%args)
    : $direction eq 'RECEIVER' ? $self->_receiver(%args)
    : error __x"message direction is 'SENDER' or 'RECEIVER', not `{dir}'"
         , dir => $direction;
}

=ci_method messageStructure XML
Returns a HASH with some collected information from a complete SOAP
message (XML::LibXML::Document or XML::LibXML::Element).  Currenty,
the HASH contains a C<header> and a C<body> key, with each an ARRAY
of element names which where found in the header resp. body.
=cut

sub messageStructure($)
{   my ($thing, $xml) = @_;
    my $env = $xml->isa('XML::LibXML::Document') ? $xml->documentElement :$xml;

    my (@header, @body);
    if(my ($header) = $env->getChildrenByLocalName('Header'))
    {   @header = map { $_->isa('XML::LibXML::Element') ? type_of_node($_) : ()}
           $header->childNodes;
    }

    if(my ($body) = $env->getChildrenByLocalName('Body'))
    {   @body = map { $_->isa('XML::LibXML::Element') ? type_of_node($_) : () }
           $body->childNodes;
    }

    +{ header => \@header
     , body   => \@body
     };
}

#------------------------------------------------
# Sender

sub _sender(@)
{   my ($self, %args) = @_;

    error __"option 'role' only for readers"  if $args{role};
    error __"option 'roles' only for readers" if $args{roles};

    my $hooks = $args{hooks}   # make copy of calling hook-list
      = $args{hooks} ? [ @{$args{hooks}} ] : [];

    my @mtom;
    push @$hooks, $self->_writer_xop_hook(\@mtom);
    my ($body,  $blabels) = $self->_writer_body  (\%args);
    my ($faults,$flabels) = $self->_writer_faults(\%args, $args{faults});

    my ($header,$hlabels) = $self->_writer_header(\%args);
    push @$hooks, $self->_writer_hook('SOAP-ENV:Header', @$header);

    my $style = $args{style} || 'none';
    if($style eq 'document')
    {   push @$hooks, $self->_writer_hook('SOAP-ENV:Body', @$body, @$faults);
    }
    elsif($style eq 'rpc' && @{$args{body}{parts}} && $args{body}{parts}[0]{type})
    {   push @$hooks, $self->_writer_hook('SOAP-ENV:Body', @$body, @$faults);
    }
    elsif($style eq 'rpc')
    {   my $procedure = $args{body}{procedure}
            or error __x"sending operation requires procedure name with RPC";
        push @$hooks, $self->_writer_rpc_hook('SOAP-ENV:Body'
          , $procedure, $body, $faults);
    }
    else
    {   error __x"unknown style `{style}'", style => $style;
    }

    #
    # Pack everything together in one procedure
    #

    my $envelope = $self->_writer('SOAP-ENV:Envelope', %args);

    sub
    {   my ($values, $charset) = ref $_[0] eq 'HASH' ? @_ : ( {@_}, undef);
        my $doc   = XML::LibXML::Document->new('1.0', $charset || 'UTF-8');
        my %copy  = %$values;  # do not destroy the calling hash
        my %data;

        $data{$_}   = delete $copy{$_} for qw/Header Body/;
        $data{Body} ||= {};

        foreach my $label (@$hlabels)
        {   defined $copy{$label} or next;
            $data{Header}{$label} ||= delete $copy{$label};
        }

        foreach my $label (@$blabels, @$flabels)
        {   defined $copy{$label} or next;
            $data{Body}{$label} ||= delete $copy{$label};
        }

        if(@$blabels==2 && !keys %{$data{Body}} ) # ignore 'Fault'
        {  # even when no params, we fill at least one body element
            $data{Body}{$blabels->[0]} = \%copy;
        }
        elsif(keys %copy)
        {   trace __x"available blocks: {blocks}",
                 blocks => [ sort @$hlabels, @$blabels, @$flabels ];
            error __x"call data not used: {blocks}", blocks => [keys %copy];
        }

        @mtom = ();   # filled via hook
        my $root = $envelope->($doc, \%data)
            or return;
        $doc->setDocumentElement($root);

        return ($doc, \@mtom)
            if wantarray;

        @mtom == 0
            or error __x"{nr} XOP objects lost in sender"
                 , nr => scalar @mtom;
        $doc;
    };
}

sub _writer_hook($$@)
{   my ($self, $type, @do) = @_;

    my $code = sub
     {  my ($doc, $data, $path, $tag) = @_;
        my %data = %$data;
        my @h = @do;
        my @childs;
        while(@h)
        {   my ($k, $c) = (shift @h, shift @h);
            if(my $v = delete $data{$k})
            {   push @childs, $c->($doc, $v);
            }
        }

        warning __x"unused values {names}", names => [keys %data]
            if keys %data;

        my $node = $doc->createElement($tag);
        $node->appendChild($_) for @childs;
        $node;
      };

   +{ type => $type, replace => $code };
}

sub _writer_rpc_hook($$$$$)
{   my ($self, $type, $procedure, $params, $faults) = @_;
    my @params = @$params;
    my @faults = @$faults;
    my $proc   = $self->schemas->prefixed($procedure);

    my $code   = sub
     {  my ($doc, $data, $path, $tag) = @_;
        my %data = %$data;
        my @f = @faults;
        my (@fchilds, @pchilds);
        while(@f)
        {   my ($k, $c) = (shift @f, shift @f);
            if(my $v = delete $data{$k}) { push @fchilds, $c->($doc, $v) }
        }
        my @p = @params;
        while(@p)
        {   my ($k, $c) = (shift @p, shift @p);
            if(my $v = delete $data{$k}) { push @pchilds, $c->($doc, $v) }
        }
        warning __x"unused values {names}", names => [keys %data]
            if keys %data;

        my $node = $doc->createElement($tag);
        if(@pchilds)
        {    my $proc = $doc->createElement($proc);
             $proc->appendChild($_) for @pchilds;
             $node->appendChild($proc);
        }
        $node->appendChild($_) for @fchilds;
        $node;
     };

   +{ type => $type, replace => $code };
}

sub _writer_header($)
{   my ($self, $args) = @_;
    my (@rules, @hlabels);

    my $header  = $args->{header} || [];
    my $soapenv = $self->_envNS;

    foreach my $h (ref $header eq 'ARRAY' ? @$header : $header)
    {   my $part    = $h->{parts}[0];
        my $label   = $part->{name};
        my $element = $part->{element};
        my $code    = $part->{writer}
         || $self->_writer($element, %$args, elements_qualified => 'TOP'
              , include_namespaces => sub {$_[0] ne $soapenv});

        push @rules, $label => $code;
        push @hlabels, $label;
    }

    (\@rules, \@hlabels);
}

sub _writer_body($)
{   my ($self, $args) = @_;
    my (@rules, @blabels);

    my $body  = $args->{body};
    my $use   = $body->{use} || 'literal';
    $use eq 'literal'
        or error __x"RPC encoded not supported by this version";

    my $parts = $body->{parts} || [];
    my $style = $args->{style};

    foreach my $part (@$parts)
    {   my $label  = $part->{name};
        my $code;
        if($part->{element})
        {   $code  = $self->_writer_body_element($args, $part);
        }
        elsif(my $type = $part->{type})
        {   $code  = $self->_writer_body_type($args, $part);
            $label = (unpack_type $type)[1];
        }
        else
        {   error __x"part {name} has neither `element' nor `type' specified"
              , name => $label;
        }

        push @rules, $label => $code;
        push @blabels, $label;
    }

    (\@rules, \@blabels);
}

sub _writer_body_element($$)
{   my ($self, $args, $part) = @_;
    my $element = $part->{element};
    my $soapenv = $self->_envNS;

    $part->{writer}
       ||= $self->_writer($element, %$args, elements_qualified => 'TOP'
            , include_namespaces => sub {$_[0] ne $soapenv});
}

sub _writer_body_type($$)
{   my ($self, $args, $part) = @_;

    $args->{style} eq 'rpc'
        or error __x"part {name} uses `type', only for rpc not {style}"
             , name => $part->{name}, style => $args->{style};

    return $part->{writer}
        if $part->{writer};

    my $soapenv = $self->_envNS;

    $part->{writer} =
        $self->schemas->compileType
          ( WRITER => $part->{type}, %$args
          , element => $args->{body}{procedure}
          , include_namespaces => sub {$_[0] ne $soapenv}
          );
}

sub _writer_faults($) { ([], []) }

sub _writer_xop_hook($)
{   my ($self, $xop_objects) = @_;

    my $collect_objects = sub {
        my ($doc, $val, $path, $tag, $r) = @_;
        return $r->($doc, $val)
            unless UNIVERSAL::isa($val, 'XML::Compile::XOP::Include');

        my $node = $val->xmlNode($doc, $path, $tag); 
        push @$xop_objects, $val;
        $node;
      };

   +{ type => 'xsd:base64Binary', replace => $collect_objects };
}

#------------------------------------------------
# Receiver

sub _receiver(@)
{   my ($self, %args) = @_;

    error __"option 'destination' only for writers"
        if $args{destination};

    error __"option 'mustUnderstand' only for writers"
        if $args{understand};

# roles are not checked (yet)
#   my $roles  = $args{roles} || $args{role} || 'ULTIMATE';
#   my @roles  = ref $roles eq 'ARRAY' ? @$roles : $roles;

    my $header = $self->_reader_header(\%args);

    my $xops;  # forward backwards pass-on
    my $body   = $self->_reader_body(\%args, \$xops);

    my $style  = $args{style} || 'document';
    my $kind   = $args{kind}  || 'request-response';
    if($style eq 'rpc')
    {   if($kind ne 'one-way' && $kind ne 'notification')
        {   my $procedure = $args{body}{procedure}
            or error __x"receiving operation requires procedure name with RPC";
            $body  = $self->_reader_body_rpc_wrapper($procedure, $body);
        }
    }
    elsif($style ne 'document')
    {   error __x"unknown style `{style}'", style => $style;
    }

    # faults are always possible
    push @$body, $self->_reader_fault_reader;

    my @hooks  = @{$self->{hooks} || []};
    push @hooks
      , $self->_reader_hook('SOAP-ENV:Header', $header)
      , $self->_reader_hook('SOAP-ENV:Body',   $body  );

    #
    # Pack everything together in one procedure
    #

    my $envelope = $self->_reader('SOAP-ENV:Envelope', %args
      , hooks  => \@hooks);

    # add simplified fault information
    my $faultdec = $self->_reader_faults(\%args, $args{faults});

    sub
    {   (my $xml, $xops) = @_;
        my $data  = $envelope->($xml);
        my @pairs = ( %{delete $data->{Header} || {}}
                    , %{delete $data->{Body}   || {}});
        while(@pairs)
        {  my $k       = shift @pairs;
           $data->{$k} = shift @pairs;
        }

        $faultdec->($data);
        $data;
    };
}

sub _reader_hook($$)
{   my ($self, $type, $do) = @_;
    my %trans = map { ($_->[1] => [ $_->[0], $_->[2] ]) } @$do; # we need copies
    my $envns = $self->_envNS;

    my $code  = sub
     {  my ($xml, $trans, $path, $label) = @_;
        my %h;
        foreach my $child ($xml->childNodes)
        {   next unless $child->isa('XML::LibXML::Element');
            my $type = type_of_node $child;
            if(my $t = $trans{$type})
            {   my $v = $t->[1]->($child);
                $h{$t->[0]} = $v if defined $v;
                next;
            }
            else
            {   trace __x"node {type} ignored, expect from {has}",
                    type => $type, has => [sort keys %trans];
            }

            return ($label => $self->replyMustUnderstandFault($type))
                if $child->getAttributeNS($envns, 'mustUnderstand') || 0;
        }
        ($label => \%h);
     };

   +{ type    => $type
    , replace => $code
    };
 
}

sub _reader_body_rpc_wrapper($$)
{   my ($self, $procedure, $body) = @_;
    my %trans = map { ($_->[1] => [ $_->[0], $_->[2] ]) } @$body;

    # this should use key_rewrite
    my $label = (unpack_type $procedure)[1];

    my $code = sub
      { my $xml = shift or return {};
        my %h;
        foreach my $child ($xml->childNodes)
        {   next unless $child->isa('XML::LibXML::Element');
            my $type = type_of_node $child;
            if(my $t = $trans{$type})
                 { $h{$t->[0]} = $t->[1]->($child) }
            else { $h{$type} = $child }
        }
        \%h;
      };

    [ [ $label => $procedure => $code ] ];
}

sub _reader_header($)
{   my ($self, $args) = @_;
    my $header = $args->{header} || [];
    my @rules;

    foreach my $h (@$header)
    {   my $part    = $h->{parts}[0];
        my $label   = $part->{name};
        my $element = $part->{element};
        my $code    = $part->{reader}
          ||= $self->_reader($element, %$args, elements_qualified => 'TOP');
        push @rules, [$label, $element, $code];
    }

    \@rules;
}

sub _reader_body($$)
{   my ($self, $args, $refxops) = @_;
    my $body  = $args->{body};
    my $parts = $body->{parts} || [];
    my @hooks = @{$args->{hooks} || []};
    push @hooks, $self->_reader_xop_hook($refxops);
    local $args->{hooks} = \@hooks;

    my @rules;
    foreach my $part (@$parts)
    {   my $label   = $part->{name};

        my ($t, $code);
        if($part->{element})
        {   ($t, $code) = $self->_reader_body_element($args, $part) }
        elsif($part->{type})
        {   ($t, $code) = $self->_reader_body_type($args, $part) }
        else
        {   error __x"part {name} has neither element nor type specified"
              , name => $label;
        }
        push @rules, [ $label, $t, $code ];
    }

    \@rules;
}

sub _reader_body_element($$)
{   my ($self, $args, $part) = @_;

    my $element = $part->{element};
    my $code    = $part->{reader}
       || $self->_reader($element, %$args, elements_qualified => 'TOP');

    return ($element, $code);
}

sub _reader_body_type($$)
{   my ($self, $args, $part) = @_;
    my $name = $part->{name};

    $args->{style} eq 'rpc'
        or error __x"only rpc style messages can use 'type' as used by {part}"
              , part => $name;

    return $part->{reader}
        if $part->{reader};

    my $type = $part->{type};
    my ($ns, $local) = unpack_type $type;

    my $r = $part->{reader} =
        $self->schemas->compileType
          ( READER => $type, %$args
          , element => $name # $args->{body}{procedure}
          );

    ($name, $r);
}

sub _reader_faults($)
{   my ($self, $args) = @_;
    sub { shift };
}

sub _reader_xop_hook($)
{   my ($self, $refxops) = @_;

    my $xop_merge = sub
      { my ($xml, $args, $path, $type, $r) = @_;
        if(my $incls = $xml->getElementsByTagNameNS(XOP10, 'Include'))
        {   my $href = $incls->shift->getAttribute('href') || ''
                or return ($type => $xml);

            $href =~ s/^cid://;
            my $xop  = $$refxops->{$href}
                or return ($type => $xml);

            return ($type => $xop);
        }

        ($type => decode_base64 $xml->textContent);
      };

   +{ type => 'xsd:base64Binary', replace => $xop_merge };
}

sub _reader(@) { my $self = shift; $self->{schemas}->reader(@_) }
sub _writer(@) { my $self = shift; $self->{schemas}->writer(@_) }

#------------------------------------------------

=section Helpers

=section Transcoding

=method roleURI URI|STRING
Translates actor/role/destination abbreviations into URIs. Various
SOAP protocol versions have different pre-defined STRINGs, which can
be abbreviated for readibility.  Returns the unmodified URI in
all other cases.

SOAP11 only defines C<NEXT>.  SOAP12 defines C<NEXT>, C<NONE>, and
C<ULTIMATE>.
=cut

sub roleURI($) { panic "not implemented" }

=method roleAbbreviation URI
Translate a role URI into a simple string, if predefined.  See
M<roleURI()>.
=cut

sub roleAbbreviation($) { panic "not implemented" }

=method replyMustUnderstandFault TYPE
Produce an error structure to be returned to the sender.
=cut

sub replyMustUnderstandFault($) { panic "not implemented" }

#----------------------

=chapter DETAILS

=section SOAP introduction

Although the specification of SOAP1.1 and WSDL1.1 are thin, the number
of special constructs are many.  And, of course, all poorly documented.
Both SOAP and WSDL have 1.2 versions, which will clear things up a lot,
but not used that often yet.

WSDL defines two kinds of messages: B<document> style SOAP and B<rpc>
style SOAP.  In I<Document style SOAP>, the messages are described in
great detail in the WSDL: the message components are all defined in
Schema's; the worst things you can (will) encounter are C<any> schema
elements which require additional manual processing.

C<RPC Literal> behaves very much the same way as document style soap,
but has one extra wrapper inside the Body of the message.

C<Encoded SOAP-RPC>, however, is a very different ball-game.  It is simple
to use on strongly typed languages, to exchange data when you create both
the client software and the server software.  You can simply autogenerate
the data encoding.  Clients written by third parties have to find the
documentation on how to use the encoded  RPC call in some other way... in
text, if they are lucky; the WSDL file does not contain the prototype
of the procedures, but that doesn't mean that they are free-format.

B<Encoded RPC> messsages are shaped to the procedures which are
being called on the server.  The body of the sent message contains the
ordered list of parameters to be passed as 'in' and 'in/out' values to the
remote procedure.  The body of the returned message lists the result value
of the procedure, followed by the ordered 'out' and 'in/out' parameters.

=section Naming types and elements

XML uses namespaces: URIs which are used as constants, grouping a set
of type and element definitions.  By using name-spaces, you can avoid
name clashes, which have frustrate many projects in history, when they
grew over a certain size... at a certain size, it becomes too hard to
think of good distriguishable names.  In such case, you must be happy
when you can place those names in a context, and use the same naming in
seperate contexts without confusion.

That being said: XML supports both namespace- and non-namespace elements
and schema's; and of cause many mixed cases.  It is by far preferred to
use namespace schemas only.  For a schema xsd file, look for the
C<targetNamespace> attribute of the C<schema> element: if present, it
uses namespaces.

In XML data, it is seen as a hassle to write the full length of the URI
each time that a namespace is addressed.  For this reason, prefixes
are used as abbreviations.  In programs, you can simply assign short
variable names to long URIs, so we do not need that trick.

Within your program, you use

  $MYSN = 'long URI of namespace';
  ... $type => "{$MYNS}typename" ...

or nicer

  use XML::Compile::Util qw/pack_type/;
  use constant MYNS => 'some uri';
  ... $type => pack_type(MYNS, 'typename') ...

The M<XML::Compile::Util> module provides a helpfull methods and constants,
as does the M<XML::Compile::SOAP::Util>.

=section Client, Proxy and Server implementations

To learn how to create clients in SOAP, read the DETAILS section in
M<XML::Compile::SOAP::Client>.  The client implementation is platform
independent.

A proxy is a complex kind of server, which in implemented
by <XML::Compile::SOAP::Server>, which is available from the
XML-Compile-SOAP-Daemon distribution.  The server is based on
M<Net::Server>, which may have some portability restrictions.

=cut

1;
