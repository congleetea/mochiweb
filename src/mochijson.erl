%% @author Bob Ippolito <bob@mochimedia.com>
%% @copyright 2006 Mochi Media, Inc.

%% @doc Yet another JSON (RFC 4627) library for Erlang.
-module(mochijson).
-author('bob@mochimedia.com').
-export([encoder/1, encode/1]).
-export([decoder/1, decode/1]).
-export([binary_encoder/1, binary_encode/1]).
-export([binary_decoder/1, binary_decode/1]).

% This is a macro to placate syntax highlighters..
-define(Q, $\").
-define(ADV_COL(S, N), S#decoder{column=N+S#decoder.column}).
-define(INC_COL(S), S#decoder{column=1+S#decoder.column}).
-define(INC_LINE(S), S#decoder{column=1, line=1+S#decoder.line}).

%% @type json_string() = atom | string() | binary()
%% @type json_number() = integer() | float()
%% @type json_array() = {array, [json_term()]}
%% @type json_object() = {struct, [{json_string(), json_term()}]}
%% @type json_term() = json_string() | json_number() | json_array() |
%%                     json_object()
%% @type encoding() = utf8 | unicode
%% @type encoder_option() = {input_encoding, encoding()} |
%%                          {handler, function()}
%% @type decoder_option() = {input_encoding, encoding()} |
%%                          {object_hook, function()}
%% @type bjson_string() = binary()
%% @type bjson_number() = integer() | float()
%% @type bjson_array() = [bjson_term()]
%% @type bjson_object() = {struct, [{bjson_string(), bjson_term()}]}
%% @type bjson_term() = bjson_string() | bjson_number() | bjson_array() |
%%                      bjson_object()
%% @type binary_encoder_option() = {handler, function()}
%% @type binary_decoder_option() = {object_hook, function()}

-record(encoder, {input_encoding=unicode,
                  handler=null}).

-record(decoder, {input_encoding=utf8,
                  object_hook=null,
                  line=1,
                  column=1,
                  state=null}).

%% @spec encoder([encoder_option()]) -> function()
%% @doc Create an encoder/1 with the given options.
encoder(Options) ->
    State = parse_encoder_options(Options, #encoder{}),
    fun (O) -> json_encode(O, State) end.

%% @spec encode(json_term()) -> iolist()
%% @doc Encode the given as JSON to an iolist.
encode(Any) ->
    json_encode(Any, #encoder{}).

%% @spec decoder([decoder_option()]) -> function()
%% @doc Create a decoder/1 with the given options.
decoder(Options) ->
    State = parse_decoder_options(Options, #decoder{}),
    fun (O) -> json_decode(O, State) end.

%% @spec decode(iolist()) -> json_term()
%% @doc Decode the given iolist to Erlang terms.
decode(S) ->
    json_decode(S, #decoder{}).

%% @spec binary_decoder([binary_decoder_option()]) -> function()
%% @doc Create a binary_decoder/1 with the given options.
binary_decoder(Options) ->
    mochijson2:decoder(Options).

%% @spec binary_encoder([binary_encoder_option()]) -> function()
%% @doc Create a binary_encoder/1 with the given options.
binary_encoder(Options) ->
    mochijson2:encoder(Options).

%% @spec binary_encode(bjson_term()) -> iolist()
%% @doc Encode the given as JSON to an iolist, using lists for arrays and
%%      binaries for strings.
binary_encode(Any) ->
    mochijson2:encode(Any).

%% @spec binary_decode(iolist()) -> bjson_term()
%% @doc Decode the given iolist to Erlang terms, using lists for arrays and
%%      binaries for strings.
binary_decode(S) ->
    mochijson2:decode(S).

%% Internal API

parse_encoder_options([], State) ->
    State;
parse_encoder_options([{input_encoding, Encoding} | Rest], State) ->
    parse_encoder_options(Rest, State#encoder{input_encoding=Encoding});
parse_encoder_options([{handler, Handler} | Rest], State) ->
    parse_encoder_options(Rest, State#encoder{handler=Handler}).

parse_decoder_options([], State) ->
    State;
parse_decoder_options([{input_encoding, Encoding} | Rest], State) ->
    parse_decoder_options(Rest, State#decoder{input_encoding=Encoding});
parse_decoder_options([{object_hook, Hook} | Rest], State) ->
    parse_decoder_options(Rest, State#decoder{object_hook=Hook}).

json_encode(true, _State) ->
    "true";
json_encode(false, _State) ->
    "false";
json_encode(null, _State) ->
    "null";
json_encode(I, _State) when is_integer(I) ->
    integer_to_list(I);
json_encode(F, _State) when is_float(F) ->
    mochinum:digits(F);
json_encode(L, State) when is_list(L); is_binary(L); is_atom(L) ->
    json_encode_string(L, State);
json_encode({array, Props}, State) when is_list(Props) ->
    json_encode_array(Props, State);
json_encode({struct, Props}, State) when is_list(Props) ->
    json_encode_proplist(Props, State);
json_encode(Bad, #encoder{handler=null}) ->
    exit({json_encode, {bad_term, Bad}});
json_encode(Bad, State=#encoder{handler=Handler}) ->
    json_encode(Handler(Bad), State).

json_encode_array([], _State) ->
    "[]";
json_encode_array(L, State) ->
    F = fun (O, Acc) ->
                [$,, json_encode(O, State) | Acc]
        end,
    [$, | Acc1] = lists:foldl(F, "[", L),
    lists:reverse([$\] | Acc1]).

json_encode_proplist([], _State) ->
    "{}";
json_encode_proplist(Props, State) ->
    F = fun ({K, V}, Acc) ->
                KS = case K of 
                         K when is_atom(K) ->
                             json_encode_string_utf8(atom_to_list(K));
                         K when is_integer(K) ->
                             json_encode_string(integer_to_list(K), State);
                         K when is_list(K); is_binary(K) ->
                             json_encode_string(K, State)
                     end,
                VS = json_encode(V, State),
                [$,, VS, $:, KS | Acc]
        end,
    [$, | Acc1] = lists:foldl(F, "{", Props),
    lists:reverse([$\} | Acc1]).

json_encode_string(A, _State) when is_atom(A) ->
    json_encode_string_unicode(xmerl_ucs:from_utf8(atom_to_list(A)));
json_encode_string(B, _State) when is_binary(B) ->
    json_encode_string_unicode(xmerl_ucs:from_utf8(B));
json_encode_string(S, #encoder{input_encoding=utf8}) ->
    json_encode_string_utf8(S);
json_encode_string(S, #encoder{input_encoding=unicode}) ->
    json_encode_string_unicode(S).

json_encode_string_utf8(S) ->
    [?Q | json_encode_string_utf8_1(S)].

json_encode_string_utf8_1([C | Cs]) when C >= 0, C =< 16#7f ->
    NewC = case C of
               $\\ -> "\\\\";
               ?Q -> "\\\"";
               _ when C >= $\s, C < 16#7f -> C;
               $\t -> "\\t";
               $\n -> "\\n";
               $\r -> "\\r";
               $\f -> "\\f";
               $\b -> "\\b";
               _ when C >= 0, C =< 16#7f -> unihex(C);
               _ -> exit({json_encode, {bad_char, C}})
           end,
    [NewC | json_encode_string_utf8_1(Cs)];
json_encode_string_utf8_1(All=[C | _]) when C >= 16#80, C =< 16#10FFFF ->
    [?Q | Rest] = json_encode_string_unicode(xmerl_ucs:from_utf8(All)),
    Rest;
json_encode_string_utf8_1([]) ->
    "\"".

json_encode_string_unicode(S) ->
    [?Q | json_encode_string_unicode_1(S)].

json_encode_string_unicode_1([C | Cs]) ->
    NewC = case C of
               $\\ -> "\\\\";
               ?Q -> "\\\"";
               _ when C >= $\s, C < 16#7f -> C;
               $\t -> "\\t";
               $\n -> "\\n";
               $\r -> "\\r";
               $\f -> "\\f";
               $\b -> "\\b";
               _ when C >= 0, C =< 16#10FFFF -> unihex(C);
               _ -> exit({json_encode, {bad_char, C}})
           end,
    [NewC | json_encode_string_unicode_1(Cs)];
json_encode_string_unicode_1([]) ->
    "\"".

dehex(C) when C >= $0, C =< $9 ->
    C - $0;
dehex(C) when C >= $a, C =< $f ->
    C - $a + 10;
dehex(C) when C >= $A, C =< $F ->
    C - $A + 10.

hexdigit(C) when C >= 0, C =< 9 ->
    C + $0;
hexdigit(C) when C =< 15 ->
    C + $a - 10.

unihex(C) when C < 16#10000 ->
    <<D3:4, D2:4, D1:4, D0:4>> = <<C:16>>,
    Digits = [hexdigit(D) || D <- [D3, D2, D1, D0]],
    [$\\, $u | Digits];
unihex(C) when C =< 16#10FFFF ->
    N = C - 16#10000,
    S1 = 16#d800 bor ((N bsr 10) band 16#3ff),
    S2 = 16#dc00 bor (N band 16#3ff),
    [unihex(S1), unihex(S2)].

json_decode(B, S) when is_binary(B) ->
    json_decode(binary_to_list(B), S);
json_decode(L, S) ->
    {Res, L1, S1} = decode1(L, S),
    {eof, [], _} = tokenize(L1, S1#decoder{state=trim}),
    Res.

decode1(L, S=#decoder{state=null}) ->
    case tokenize(L, S#decoder{state=any}) of
        {{const, C}, L1, S1} ->
            {C, L1, S1};
        {start_array, L1, S1} ->
            decode_array(L1, S1#decoder{state=any}, []);
        {start_object, L1, S1} ->
            decode_object(L1, S1#decoder{state=key}, [])
    end.

make_object(V, #decoder{object_hook=null}) ->
    V;
make_object(V, #decoder{object_hook=Hook}) ->
    Hook(V).

decode_object(L, S=#decoder{state=key}, Acc) ->
    case tokenize(L, S) of
        {end_object, Rest, S1} ->
            V = make_object({struct, lists:reverse(Acc)}, S1),
            {V, Rest, S1#decoder{state=null}};
        {{const, K}, Rest, S1} when is_list(K) ->
            {colon, L2, S2} = tokenize(Rest, S1),
            {V, L3, S3} = decode1(L2, S2#decoder{state=null}),
            decode_object(L3, S3#decoder{state=comma}, [{K, V} | Acc])
    end;
decode_object(L, S=#decoder{state=comma}, Acc) ->
    case tokenize(L, S) of
        {end_object, Rest, S1} ->
            V = make_object({struct, lists:reverse(Acc)}, S1),
            {V, Rest, S1#decoder{state=null}};
        {comma, Rest, S1} ->
            decode_object(Rest, S1#decoder{state=key}, Acc)
    end.

decode_array(L, S=#decoder{state=any}, Acc) ->
    case tokenize(L, S) of
        {end_array, Rest, S1} ->
            {{array, lists:reverse(Acc)}, Rest, S1#decoder{state=null}};
        {start_array, Rest, S1} ->
            {Array, Rest1, S2} = decode_array(Rest, S1#decoder{state=any}, []),
            decode_array(Rest1, S2#decoder{state=comma}, [Array | Acc]);
        {start_object, Rest, S1} ->
            {Array, Rest1, S2} = decode_object(Rest, S1#decoder{state=key}, []),
            decode_array(Rest1, S2#decoder{state=comma}, [Array | Acc]);
        {{const, Const}, Rest, S1} ->
            decode_array(Rest, S1#decoder{state=comma}, [Const | Acc])
    end;
decode_array(L, S=#decoder{state=comma}, Acc) ->
    case tokenize(L, S) of
        {end_array, Rest, S1} ->
            {{array, lists:reverse(Acc)}, Rest, S1#decoder{state=null}};
        {comma, Rest, S1} ->
            decode_array(Rest, S1#decoder{state=any}, Acc)
    end.

tokenize_string(IoList=[C | _], S=#decoder{input_encoding=utf8}, Acc)
  when is_list(C); is_binary(C); C >= 16#7f ->
    List = xmerl_ucs:from_utf8(iolist_to_binary(IoList)),
    tokenize_string(List, S#decoder{input_encoding=unicode}, Acc);
tokenize_string("\"" ++ Rest, S, Acc) ->
    {lists:reverse(Acc), Rest, ?INC_COL(S)};
tokenize_string("\\\"" ++ Rest, S, Acc) ->
    tokenize_string(Rest, ?ADV_COL(S, 2), [$\" | Acc]);
tokenize_string("\\\\" ++ Rest, S, Acc) ->
    tokenize_string(Rest, ?ADV_COL(S, 2), [$\\ | Acc]);
tokenize_string("\\/" ++ Rest, S, Acc) ->
    tokenize_string(Rest, ?ADV_COL(S, 2), [$/ | Acc]);
tokenize_string("\\b" ++ Rest, S, Acc) ->
    tokenize_string(Rest, ?ADV_COL(S, 2), [$\b | Acc]);
tokenize_string("\\f" ++ Rest, S, Acc) ->
    tokenize_string(Rest, ?ADV_COL(S, 2), [$\f | Acc]);
tokenize_string("\\n" ++ Rest, S, Acc) ->
    tokenize_string(Rest, ?ADV_COL(S, 2), [$\n | Acc]);
tokenize_string("\\r" ++ Rest, S, Acc) ->
    tokenize_string(Rest, ?ADV_COL(S, 2), [$\r | Acc]);
tokenize_string("\\t" ++ Rest, S, Acc) ->
    tokenize_string(Rest, ?ADV_COL(S, 2), [$\t | Acc]);
tokenize_string([$\\, $u, C3, C2, C1, C0 | Rest], S, Acc) ->
    % coalesce UTF-16 surrogate pair?
    C = dehex(C0) bor
        (dehex(C1) bsl 4) bor
        (dehex(C2) bsl 8) bor 
        (dehex(C3) bsl 12),
    tokenize_string(Rest, ?ADV_COL(S, 6), [C | Acc]);
tokenize_string([C | Rest], S, Acc) when C >= $\s; C < 16#10FFFF ->
    tokenize_string(Rest, ?ADV_COL(S, 1), [C | Acc]).
    
tokenize_number(IoList=[C | _], Mode, S=#decoder{input_encoding=utf8}, Acc)
  when is_list(C); is_binary(C); C >= 16#7f ->
    List = xmerl_ucs:from_utf8(iolist_to_binary(IoList)),
    tokenize_number(List, Mode, S#decoder{input_encoding=unicode}, Acc);
tokenize_number([$- | Rest], sign, S, []) ->
    tokenize_number(Rest, int, ?INC_COL(S), [$-]);
tokenize_number(Rest, sign, S, []) ->
    tokenize_number(Rest, int, S, []);
tokenize_number([$0 | Rest], int, S, Acc) ->
    tokenize_number(Rest, frac, ?INC_COL(S), [$0 | Acc]);
tokenize_number([C | Rest], int, S, Acc) when C >= $1, C =< $9 ->
    tokenize_number(Rest, int1, ?INC_COL(S), [C | Acc]);
tokenize_number([C | Rest], int1, S, Acc) when C >= $0, C =< $9 ->
    tokenize_number(Rest, int1, ?INC_COL(S), [C | Acc]);
tokenize_number(Rest, int1, S, Acc) ->
    tokenize_number(Rest, frac, S, Acc);
tokenize_number([$., C | Rest], frac, S, Acc) when C >= $0, C =< $9 ->
    tokenize_number(Rest, frac1, ?ADV_COL(S, 2), [C, $. | Acc]);
tokenize_number([E | Rest], frac, S, Acc) when E == $e; E == $E ->
    tokenize_number(Rest, esign, ?INC_COL(S), [$e, $0, $. | Acc]);
tokenize_number(Rest, frac, S, Acc) ->
    {{int, lists:reverse(Acc)}, Rest, S};
tokenize_number([C | Rest], frac1, S, Acc) when C >= $0, C =< $9 ->
    tokenize_number(Rest, frac1, ?INC_COL(S), [C | Acc]);
tokenize_number([E | Rest], frac1, S, Acc) when E == $e; E == $E ->
    tokenize_number(Rest, esign, ?INC_COL(S), [$e | Acc]);
tokenize_number(Rest, frac1, S, Acc) ->
    {{float, lists:reverse(Acc)}, Rest, S};
tokenize_number([C | Rest], esign, S, Acc) when C == $-; C == $+ ->
    tokenize_number(Rest, eint, ?INC_COL(S), [C | Acc]);
tokenize_number(Rest, esign, S, Acc) ->
    tokenize_number(Rest, eint, S, Acc);
tokenize_number([C | Rest], eint, S, Acc) when C >= $0, C =< $9 ->
    tokenize_number(Rest, eint1, ?INC_COL(S), [C | Acc]);
tokenize_number([C | Rest], eint1, S, Acc) when C >= $0, C =< $9 ->
    tokenize_number(Rest, eint1, ?INC_COL(S), [C | Acc]);
tokenize_number(Rest, eint1, S, Acc) ->
    {{float, lists:reverse(Acc)}, Rest, S}.

tokenize([], S=#decoder{state=trim}) ->
    {eof, [], S};
tokenize([L | Rest], S) when is_list(L) ->
    tokenize(L ++ Rest, S);
tokenize([B | Rest], S) when is_binary(B) ->
    tokenize(xmerl_ucs:from_utf8(B) ++ Rest, S);
tokenize("\r\n" ++ Rest, S) ->
    tokenize(Rest, ?INC_LINE(S));
tokenize("\n" ++ Rest, S) ->
    tokenize(Rest, ?INC_LINE(S));
tokenize([C | Rest], S) when C == $\s; C == $\t ->
    tokenize(Rest, ?INC_COL(S));
tokenize("{" ++ Rest, S) ->
    {start_object, Rest, ?INC_COL(S)};
tokenize("}" ++ Rest, S) ->
    {end_object, Rest, ?INC_COL(S)};
tokenize("[" ++ Rest, S) ->
    {start_array, Rest, ?INC_COL(S)};
tokenize("]" ++ Rest, S) ->
    {end_array, Rest, ?INC_COL(S)};
tokenize("," ++ Rest, S) ->
    {comma, Rest, ?INC_COL(S)};
tokenize(":" ++ Rest, S) ->
    {colon, Rest, ?INC_COL(S)};
tokenize("null" ++ Rest, S) ->
    {{const, null}, Rest, ?ADV_COL(S, 4)};
tokenize("true" ++ Rest, S) ->
    {{const, true}, Rest, ?ADV_COL(S, 4)};
tokenize("false" ++ Rest, S) ->
    {{const, false}, Rest, ?ADV_COL(S, 5)};
tokenize("\"" ++ Rest, S) ->
    {String, Rest1, S1} = tokenize_string(Rest, ?INC_COL(S), []),
    {{const, String}, Rest1, S1};
tokenize(L=[C | _], S) when C >= $0, C =< $9; C == $- ->
    case tokenize_number(L, sign, S, []) of
        {{int, Int}, Rest, S1} ->
            {{const, list_to_integer(Int)}, Rest, S1};
        {{float, Float}, Rest, S1} ->
            {{const, list_to_float(Float)}, Rest, S1}
    end.

