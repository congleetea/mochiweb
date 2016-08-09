%% @author Bob Ippolito <bob@mochimedia.com>
%% @copyright 2007 Mochi Media, Inc.

%% @doc HTTP server.

-module(mochiweb_http).

-author('bob@mochimedia.com').

-export([start_link/2]).
-export([init/2, loop/2]).
-export([after_response/3, reentry/2]).
-export([parse_range_request/1, range_skip_length/2]).

-define(REQUEST_RECV_TIMEOUT, 300000).   %% timeout waiting for request line
-define(HEADERS_RECV_TIMEOUT, 30000).    %% timeout waiting for headers

-define(MAX_HEADERS, 1000).

-ifdef(gen_tcp_r15b_workaround).
r15b_workaround() -> true.
-else.
r15b_workaround() -> false.
-endif.

%% conglistener9http_1: 和emqttd_client中启动进程不一样,没有使用proc_lib库,这样启动的对于捕捉信号不太方便。
%% 这里产生给客户端占用的第一个进程(websocket连接每个占用三个进程).
start_link(Conn, Callback) ->
    {ok, spawn_link(?MODULE, init, [Conn, Callback])}.

init(Conn, Callback) ->
    %% conglistener9http_2: 和mqtt连接一样，等待acceptor的go消息, acceptor彻底将socket的控制权交给connection,  
    %% 信息首先在这个进程初步处理，然后在转到emqttd_ws_client.
    {ok, NewConn} = Conn:wait(),
    loop(NewConn, Callback).

loop(Conn, Callback) ->
    %% 将socket设置参数{packet,http}将会把收到的数据通过erlang:decode_packet/3进行相应的格式化。
    ok = Conn:setopts([{packet, http}]),
    request(Conn, Callback).

request(Conn, Callback) ->
    %% 将socket设置为被动接受模式.
    ok = Conn:setopts([{active, once}]),
    receive
        %% why: 为什么要{packet,httph}?
        %% 处理请求报文.
        {Protocol, _, {http_request, Method, Path, Version}} when Protocol == http orelse Protocol == ssl ->
            ok = Conn:setopts([{packet, httph}]),
            headers(Conn, {Method, Path, Version}, [], Callback, 0);
        {Protocol, _, {http_error, "\r\n"}} when Protocol == http orelse Protocol == ssl ->
            request(Conn, Callback);
        {Protocol, _, {http_error, "\n"}} when Protocol == http orelse Protocol == ssl ->
            request(Conn, Callback);
        {tcp_closed, _} ->
            Conn:close(),
            exit(normal);
        {ssl_closed, _} ->
            Conn:close(),
            exit(normal);
        Other ->
            handle_invalid_msg_request(Other, Conn)
    after ?REQUEST_RECV_TIMEOUT ->
        Conn:close(),
        exit(normal)
    end.

reentry(Conn, Callback) ->
    fun (Req) ->
            ?MODULE:after_response(Conn, Callback, Req)
    end.

headers(Conn, Request, Headers, _Callback, ?MAX_HEADERS) ->
    %% Too many headers sent, bad request.
    ok = Conn:setopts([{packet, raw}]),
    handle_invalid_request(Conn, Request, Headers);

headers(Conn, Request, Headers, Callback, HeaderCount) ->
    ok = Conn:setopts([{active, once}]),
    receive
        %% http_eoh表示报文头部结束，准备接收消息正文.
        {Protocol, _, http_eoh} when Protocol == http orelse Protocol == ssl ->
            Req = new_request(Conn, Request, Headers),
            callback(Callback, Req),
            ?MODULE:after_response(Conn, Callback, Req);
        %% http_header 处理协议头
        {Protocol, _, {http_header, _, Name, _, Value}} when Protocol == http orelse Protocol == ssl ->
            headers(Conn, Request, [{Name, Value} | Headers], Callback, 1 + HeaderCount);
        {tcp_closed, _} ->
            Conn:close(),
            exit(normal);
        Other ->
            handle_invalid_msg_request(Other, Conn, Request, Headers)
    after ?HEADERS_RECV_TIMEOUT ->
        Conn:close(),
        exit(normal)
    end.


-spec handle_invalid_msg_request(term(), esockd_connection:connection()) -> no_return().
handle_invalid_msg_request(Msg, Conn) ->
    handle_invalid_msg_request(Msg, Conn, {'GET', {abs_path, "/"}, {0,9}}, []).

-spec handle_invalid_msg_request(term(), esockd_connection:connection(), term(), term()) -> no_return().
handle_invalid_msg_request(Msg, Conn, Request, RevHeaders) ->

    case {Msg, r15b_workaround()} of
        {{tcp_error,_,emsgsize}, true} ->
            %% R15B02 returns this then closes the socket, so close and exit
            Conn:close(),
            exit(normal);
        _ ->
            handle_invalid_request(Conn, Request, RevHeaders)
    end.

-spec handle_invalid_request(esockd_connection:connection(), term(), term()) -> no_return().
handle_invalid_request(Conn, Request, RevHeaders) ->
    Req = new_request(Conn, Request, RevHeaders),
    Req:respond({400, [], []}),
    Conn:close(),
    exit(normal).
%% 如果消息正文非空，就要{packet,raw}状态，让其停止http解析，把接收到的数据转换成{tcp,Socket,Data}
new_request(Conn, Request, RevHeaders) ->
    ok = Conn:setopts([{packet, raw}]),
    mochiweb:new_request({Conn, Request, lists:reverse(RevHeaders)}).

after_response(Conn, Callback, Req) ->
    case Req:should_close() of
        true ->
            Conn:close(),
            exit(normal);
        false ->
            Req:cleanup(),
            erlang:garbage_collect(),
            ?MODULE:loop(Conn, Callback)
    end.

parse_range_request("bytes=0-") ->
    undefined;
parse_range_request(RawRange) when is_list(RawRange) ->
    try
        "bytes=" ++ RangeString = RawRange,
        RangeTokens = [string:strip(R) || R <- string:tokens(RangeString, ",")],
        Ranges = [R || R <- RangeTokens, string:len(R) > 0],
        lists:map(fun ("-" ++ V)  ->
                          {none, list_to_integer(V)};
                      (R) ->
                          case string:tokens(R, "-") of
                              [S1, S2] ->
                                  {list_to_integer(S1), list_to_integer(S2)};
                              [S] ->
                                  {list_to_integer(S), none}
                          end
                  end,
                  Ranges)
    catch
        _:_ ->
            fail
    end.

range_skip_length(Spec, Size) ->
    case Spec of
        {none, R} when R =< Size, R >= 0 ->
            {Size - R, R};
        {none, _OutOfRange} ->
            {0, Size};
        {R, none} when R >= 0, R < Size ->
            {R, Size - R};
        {_OutOfRange, none} ->
            invalid_range;
        {Start, End} when 0 =< Start, Start =< End, End < Size ->
            {Start, End - Start + 1};
        {Start, End} when 0 =< Start, Start =< End, End >= Size ->
            {Start, Size - Start};
        {_OutOfRange, _End} ->
            invalid_range
    end.
%% conglistener9http_3: 执行回调：emqttd_http:handle_request
callback({M, F, A}, Req) ->
    erlang:apply(M, F, [Req | A]);
callback({M, F}, Req) ->
    M:F(Req);
callback(Callback, Req) when is_function(Callback) ->
    Callback(Req).
