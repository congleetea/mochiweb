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
%% 这里Callback = {emqttd_http, handle_request, []}
start_link(Conn, Callback) ->
    {ok, spawn_link(?MODULE, init, [Conn, Callback])}.

init(Conn, Callback) ->
    %% conglistener9http_2: 和mqtt连接一样，等待acceptor的go消息, acceptor彻底将socket的控制权交给connection,
    %% 信息首先在这个进程初步处理，然后在转到emqttd_ws_client.
    {ok, NewConn} = Conn:wait(),                % wait接受go消息之后，执行ssl的升级(if necessary).
    loop(NewConn, Callback).

loop(Conn, Callback) ->
    %% 将socket设置参数{packet,http}将会在运行时系统ERTS中把收到的数据通过erlang:decode_packet/3进行相应的格式化为HttpPacket。
    ok = Conn:setopts([{packet, http}]),
    request(Conn, Callback).                    % 循环接受消息并处理.

%% WebSocket和http的关系的唯一关系就是他的握手请求可以作为一个升级请求(upgrade request)经由HTTP服务器解释，握手结束之后，
%% WebSocket就科http没有一点关系了。
request(Conn, Callback) ->
    %% 将socket设置为被动接受模式, 然后坐等有套接字发出的消息，如果有消息来，就接受数据并进行处理。此时套接字又被重置成了被动模式.
    %% 于是在下一次循环中，我们需要再次启动{active,once}并等待消息, 每次都会这么多。
    ok = Conn:setopts([{active, once}]),
    receive
        %% why: 为什么要{packet,httph}?
        %% 处理请求行, 提取相关信息，有headers处理.
        {Protocol, _, {http_request, Method, Path, Version}} when Protocol == http orelse Protocol == ssl ->
            %% httph这两类很少使用，因为放第一行被读取之后，socket会被自动由内部从http/http_bin转化为httph/httph_bin,
            %% 但是也有一些有用的场合，比如从块编码(chunked encoding)中解析尾部。
            ok = Conn:setopts([{packet, httph}]),
            %% 最后一个参数是0，表示还没有接收到协议头，在headers中去接收和处理。
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
    %% 每次收到的请求行信息被提取之后，重新设置{active,once}接收更多消息.
    ok = Conn:setopts([{active, once}]),
    %% 处理完请求行之后，一般会收到若干协议头。前面设置了{packet,http}，套接字会自动解析各个HTTP协议头，
    %% 然后发成{http,_Sock,{http_header,Length,Name,_ReservedField,Value}}的形式。
    receive
        %% http_eoh表示报文协议头部结束，准备接收消息正文, 这时候要设置{packet,raw}，让它停止http解析，把接收到的数据
        %% 转换成普通的{tcp,Sock,Data}格式，因为http的报头已经被解析出来了, 剩下的就是tcp包了.
        {Protocol, _, http_eoh} when Protocol == http orelse Protocol == ssl ->
            %% 将请求信息整合得到Req = {mochiweb_request, [Conn, Method, RawPath, Version, Headers]}. 然后执行回调, 就是{emqttd_http, handle_request, []}
            Req = new_request(Conn, Request, Headers),
            %% jump to emqttd_http:handle_request([Req]) (将Req，加加在原有参数前面, 原有参数是[])
            %% 最后执行emqttd_http:handle_request({mochiweb_request, [Conn, Method, RawPath, Version, Headers]})
            io:format("~n~p:~p:Request=~p~n", [?MODULE, ?LINE, Request]),
            callback(Callback, Req),
            %% 通过after_response处理返回响应之后的事.
            ?MODULE:after_response(Conn, Callback, Req);
        %% http_header协议头, 处理协议头,主要工作放在headers/5中处理, 主要是把协议头信息放在一个list里面, 协议头有个数限制。
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
%% 1) 处理完协议头之后，就要设置{packet,raw}，让其停止http解析，把接收到的数据转换成{tcp,Socket,Data}
%% 2) 之前解析的协议头顺序是反的，利用list:reverse进行一次翻转.
%% 3) 将请求行信息和协议头信息整合之后得到新的NewReq.
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
