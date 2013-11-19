-module(torrent_peer).

-behavior(gen_server).

-export([init/1, handle_info/2, handle_cast/2, start/5, terminate/2]).
-export([download/2, coordinator_have/2]).

-include("torrent.hrl").

-record(state, {
          owner :: pid(),
          sock,
          blocks,

          info :: #info{},

          im_choked           = true,
          im_interested       = false,

          peer_is_choked      = true,
          peer_is_interested  = false,

          i_have,
          want = [],
          file                                 :: file:io_device(),
          piece_length                         :: pos_integer(),
          inq                 = queue:new(),
          outq                = queue:new(),
          last_seen           = os:timestamp() :: erlang:timestamp(),
          inflight            = ordsets:new()  :: ordsets:ordsets(),

          upload_bps        = ?UPLOAD_BYTES_PER_SECOND,
          upload_allowance = 0,
          timer
}).

%% API

download(PeerPID, Index) -> gen_server:cast(PeerPID, {download, Index}).
coordinator_have(PeerPID, Index) -> gen_server:cast(PeerPID, {have, Index}).

%% gen_server logic

start(TSock, Info, File, Have, Owner) ->
    {ok, PID} = gen_server:start(?MODULE, [TSock,Info,File,Have,Owner], []),
    gen_tcp:controlling_process(TSock, PID),
    PID ! init,
    {ok, PID}.

init([Sock,Info,File,Have,Owner]) ->
    Blocks = ets:new(torrent_blocks, [ordered_set]),
    {ok, #state{ blocks=Blocks, sock=Sock, info=Info, file=File, i_have=Have, owner=Owner }}.

handle_info(init, State=#state{ sock=Sock, i_have=BitSet }) ->
    %% initialize
    Timer = erlang:start_timer(5000+random:uniform(10000), self(), ten_sec_timer),
    State1 = State#state{ timer =  Timer },
    ok = inet:setopts(Sock, [{active, once}, {packet, 4}]),
    case bitset:is_empty(BitSet) of
        true  -> State3 = State1;
        false -> {ok, State3} = send({bitfield, BitSet},State1)
    end,
    do_work(State3);

handle_info({tcp_closed, TSock}, State=#state{ sock=TSock}) ->
    {stop, normal, State};

handle_info({tcp, TSock, Packet}, State=#state{ sock=TSock, info=Info }) ->
    Message = torrent_protocol:decode_packet(Packet, Info),
    io:format("~p received ~P~n", [self(), Message, 16]),
    {ok, State2} = handle_incoming(Message, State#state{ last_seen=os:timestamp() }),
    inet:setopts(TSock, [{active,once}]),
    do_work(State2);

handle_info({timeout, _, ten_sec_timer}, State=#state{ upload_allowance=Rest, upload_bps=DataPerSecond }) ->
    Timer = erlang:start_timer(10000, self(), ten_sec_timer),
    {ok, State2} = send(keep_alive, State),
    do_work(State2#state{ upload_allowance=(10*DataPerSecond)+min(0,Rest), timer=Timer }).

handle_cast({have, Index}, State=#state{ want=Want, i_have=HereSet }) ->
    case ordsets:is_element(Index, Want) of
        false -> {ok, State2} = send({have, Index}, State);
        true  -> {ok, State2} = cancel(Index, State)
    end,
    do_work(State2#state{ i_have=bitset:set(HereSet, Index), want=ordsets:del_element(Index, Want) });

handle_cast({download, Index}, State=#state{ info=Info }) ->
    {ok, State2} = send({interest, true}, State),
    PieceLength = torrent_file:piece_length(Index, Info),
    Offsets0 = lists:seq(0, PieceLength-1, ?BLOCK_SIZE),
    io:format("~p downloading ~p; length=~p; blocks=~p~n", [self(), Index, PieceLength, length(Offsets0)]),
    QOut2 = lists:foldl(fun(Offset,Q) ->
                               Length = min(?BLOCK_SIZE, PieceLength-Offset),
                               queue:in({request, Index, Offset, Length}, Q)
                       end,
                       State2#state.outq,
                       Offsets0),
    do_work(State2#state{ outq=QOut2 }).

terminate(_Reason, _State) ->
  io:format("~p peer stopping with reason: ~p~n", [self(), _Reason]),
  ok.

%% Internal functions

cancel(Index, State=#state{ inflight = InFlight }) ->
  ToCancel = ordsets:filter(fun({request, I, _, _}) -> I==Index end, InFlight),
  {ok, State1} = ordsets:fold(fun({request, I, O, L}, {ok, State0}) -> send({cancel, I, O, L}, State0) end,
    {ok, State},
    ToCancel),
  {ok, State1#state{ inflight=ordsets:subtract(InFlight, ToCancel),
                     outq=queue:filter(fun({request, I, _, _}) -> I == Index end, State1#state.outq) }}.

do_work(State) ->
    % io:format("~p do_work ~P~n", [self(), State#state{ info=none }, 30]),
    {ok, State1} = request_work(State),
    {ok, State2} = send_requests(State1),
    {ok, State3} = update_interest(State2),
    {ok, State4} = maybe_unchoke_peer(State3),
    {ok, State5} = send_replies(State4),
    {noreply, State5}.

request_work(State=#state{ outq=QOut, inflight=InFlight, want=Want }) ->
    case (Want /= []) andalso (queue:len(QOut) + ordsets:size(InFlight)) < ?MAX_INFLIGHT_REQUESTS of
        true ->
            download(self(), lists:nth( random:uniform(length(Want)) , Want)),
            {ok, State};
        false ->
            {ok, State}
    end.

%% if we're not choked, try to send up to MAX_INFLIGHT_REQUESTS requests
send_requests(State=#state{ im_choked=false, outq=QOut, inflight=InFlight }) ->
    case ordsets:size(InFlight) < ?MAX_INFLIGHT_REQUESTS of
        true ->
            case queue:out(QOut) of
                {{value, Message}, QOut2} ->
                    {ok, State2} = send(Message, State),
                    send_requests(State2#state{ outq=QOut2, inflight=ordsets:add_element(Message, InFlight) });
                {empty, _} ->
                    {ok, State}
            end;
        false ->
            {ok, State}
    end;
send_requests(State) ->
    {ok, State}.

%% ensure that we have set interest=false if we have no outstanding requests
update_interest(State=#state{ im_interested=true, inflight=[], outq=QOut }) ->
    case queue:is_empty(QOut) of
        true  -> send({interest, false}, State);
        false -> {ok, State}
    end;
update_interest(State) ->
    {ok, State}.

%% unchoke peer if we have excess outbound bandwidth
maybe_unchoke_peer(State=#state{ peer_is_choked=true, upload_allowance=Data }) when Data > 0 ->
    send({choke, false}, State);
maybe_unchoke_peer(State) ->
    {ok, State}.

send_replies(State=#state{ inq=Q,
                           peer_is_choked=false,
                           peer_is_interested=true,
                           upload_allowance=Allowance,
                           piece_length=PieceLength,
                           file=File }) ->
    case Allowance > 0 of
        true ->
            case queue:out(Q) of
                {empty, _} ->
                    {ok, State};
                {{value, {requests, Index, Offset, Length}}, Q2} ->
                    FileOffset = (Index * PieceLength) + Offset,
                    case file:pread(File, FileOffset, Length) of
                        {ok, Data} ->
                            ets:update_counter(torrent_stats, (State#state.info)#info.info_hash, {3, Length}),
                            {ok, State2} = send({block, Index, Offset, Data},
                                                State=#state{ inq=Q2,
                                                              upload_allowance=Allowance-Length
                                                            }),
                            send_replies(State2)
                    end
            end;
        false ->
            send({choke, true}, State)
    end;
send_replies(State) ->
    {ok, State}.

send(Msg, State) ->
 %io:format("~p sending ~p~n", [self(), Msg]),
 send1(Msg, State).

send1({interest, Interest}, State=#state{ im_interested=Interest }) ->
    {ok, State};
send1({interest, Interest}=Message, State=#state{ sock=Sock, info=Info }) ->
    ok = gen_tcp:send(Sock, torrent_protocol:encode_packet(Message, Info)),
    {ok, State#state{ im_interested=Interest }};
send1({choke, Choke}, State=#state{ peer_is_choked=Choke }) ->
    {ok, State};
send1({choke, Choke}=Message, State=#state{ sock=Sock, info=Info }) ->
    ok = gen_tcp:send(Sock, torrent_protocol:encode_packet(Message, Info)),
    {ok, State#state{ peer_is_choked=Choke }};
send1({request, _, _, _}=Message, State=#state{ im_interested=false, im_choked=Choked }) ->
    Choked = false, %% assertion
    {ok, State2} = send({interest, true}, State),
    send(Message, State2);
send1(Message, State=#state{ sock=Sock, info=Info }) ->
    ok = gen_tcp:send(Sock, torrent_protocol:encode_packet(Message, Info)),
    {ok, State}.



%% Handle incoming traffic

handle_incoming({interest, Bool}, State) ->
    {ok, State#state{ peer_is_interested=Bool }};
handle_incoming({choke, true}, State=#state{ inflight=InFlight, outq=QOut }) ->
    {ok, State#state{ im_choked=true, inflight=[], outq=ordsets:fold(fun queue:in_r/2, QOut, InFlight)  }};
handle_incoming({choke, false}, State) ->
    {ok, State#state{ im_choked=false }};
handle_incoming({bitfield, PeerHas}, State=#state{ i_have = IHave }) ->
    Want = bitset:to_ordset( bitset:bit_andnot(PeerHas, IHave) ),
    io:format("~p WANT: ~p~n", [self(), Want]),
    {ok, State#state{ want=Want }};
handle_incoming({have, Index}, State=#state{ want=Want, outq=QOut, i_have = IHave }) ->
    case bitset:is_set(IHave, Index) of
      true  -> {ok, State};
      false -> (queue:len(QOut) < 10 * ?MAX_INFLIGHT_REQUESTS) andalso download(self(), Index),
               {ok, State#state{ want=ordsets:add_element(Index, Want) }}
    end;
handle_incoming({cancel, Index, Offset, Length}, State=#state{ inq=QIn }) ->
    QIn2 = queue:filter(fun({request, I, O, L}) when I==Index, O==Offset, L==Length -> false; (_) -> true end, QIn),
    {ok, State#state{ inq=QIn2 }};
handle_incoming({block, Index, Offset, Data},
                State=#state{ blocks=Blocks, owner=Owner, file=File, info=Info, inflight=InFlight }) ->
    ets:update_counter(torrent_stats, Info#info.info_hash, {2, byte_size(Data)}),
    true = ets:insert(Blocks,{{Index,Offset},Data}),
    PieceData = ets:match(Blocks, {{Index,'_'}, '$1'}),
    case iolist_size(PieceData) == torrent_file:piece_length(Index, Info) of
      true ->
        ets:match_delete(Blocks, {{Index,'_'}, '_'}),
        case torrent_file:piece_sha(Index, Info) == crypto:hash(sha, PieceData) of
          true  -> file:pwrite(File, torrent_file:piece_offset(Index, Info), PieceData),
            io:format("~p ** completed ~p~n", [self(), Index]),
            torrent_file:downloaded(Owner, Index);
          false ->
            io:format("~p ** BAD! ~p~n", [self(), Index])
        end;
      false ->
        ok
    end,
    {ok, State#state{ inflight=ordsets:del_element({request,Index,Offset,byte_size(Data)}, InFlight) }};
handle_incoming({request, _, _, _}, State=#state{ peer_is_choked=true }) ->
    {ok, State}; % ignore
handle_incoming({request, _, _, _}=Request, State=#state{ inq=QIn }) ->
    {ok, State#state{ inq=queue:in(Request, QIn) }};
handle_incoming(keep_alive, State) ->
    {ok, State}.

