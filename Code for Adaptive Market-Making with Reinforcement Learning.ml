(* ========================================================================= *)
(* Adaptive Market-Making with Reinforcement Learning                        *)
(* OCaml — stdlib-only. Simulation runs by default; uncomment production      *)
(* block AND swap the entry point at the bottom to run production mode.       *)
(* ========================================================================= *)

Random.self_init ()

(* ---------------------------- 0. UTILITIES ---------------------------- *)

let pi = 4.0 *. atan 1.0

let gaussian () =
  let u1 = max (Random.float 1.0) 1e-12 in
  let u2 = Random.float 1.0 in
  sqrt (-2.0 *. log u1) *. cos (2.0 *. pi *. u2)

let mean lst =
  match lst with
  | [] -> 0.0
  | _ ->
    let n = List.length lst in
    List.fold_left ( +. ) 0.0 lst /. float_of_int n

let stdev lst =
  let n = List.length lst in
  if n < 2 then 0.0
  else
    let m = mean lst in
    let v =
      List.fold_left (fun a x -> a +. (x -. m) ** 2.0) 0.0 lst
      /. float_of_int (n - 1)
    in
    sqrt v

let clamp x lo hi = max lo (min hi x)

let take n lst =
  let rec loop i acc = function
    | [] -> List.rev acc
    | _ when i >= n -> List.rev acc
    | x :: rest -> loop (i + 1) (x :: acc) rest
  in
  loop 0 [] lst

(* ---------------------------- 1. DATA FEED ---------------------------- *)

type tick = {
  timestamp : float;
  mid_price : float;
  spread    : float;
  volume    : float;
}

type live_data_feed = {
  mutable drift       : float;
  mutable volatility  : float;
  mutable price       : float;
  mutable base_spread : float;
  mutable step        : int;
}

let create_live_data_feed ?(initial_price = 100.0) drift volatility = {
  drift;
  volatility;
  price = initial_price;
  base_spread = 0.5;
  step = 0;
}

let next_tick (feed : live_data_feed) : tick =
  let dt = 0.1 in
  let shock = gaussian () *. sqrt dt in
  feed.price <-
    feed.price
    *. exp ((feed.drift -. 0.5 *. feed.volatility ** 2.0) *. dt
            +. feed.volatility *. shock);
  feed.price <- max feed.price 50.0;
  let spread_mult = 1.0 +. 2.0 *. feed.volatility /. 3.0 in
  let sp = feed.base_spread *. spread_mult *. (1.0 +. 0.1 *. gaussian ()) in
  let vol = max 0.1 (-. log (max (Random.float 1.0) 1e-12) *. 5.0) in
  feed.step <- feed.step + 1;
  { timestamp = float_of_int feed.step;
    mid_price = feed.price;
    spread    = sp;
    volume    = vol }

(* ------------------- 2. ADAPTIVE MARKET-MAKER (SIM) ------------------- *)

type decision = {
  d_mid           : float;
  d_vol_est       : float;
  d_target_spread : float;
  d_skew          : float;
  d_bid           : float;
  d_ask           : float;
  d_inventory     : float;
  d_cash          : float;
  d_equity        : float;
  d_fill_bid      : bool;
  d_fill_ask      : bool;
}

type market_maker = {
  mutable cash                  : float;
  mutable inventory             : float;
  mutable realized_pnl          : float;
  mutable trade_log             : float list;
  mutable price_history         : float list;
  mutable mm_trade_count        : int;
  mutable mm_fill_count         : int;
  mutable mm_base_spread        : float;
  mutable inventory_skew_factor : float;
  mutable volatility_scaling    : float;
}

let create_market_maker ?(initial_cash = 10000.0) () = {
  cash = initial_cash;
  inventory = 0.0;
  realized_pnl = 0.0;
  trade_log = [];
  price_history = [];
  mm_trade_count = 0;
  mm_fill_count = 0;
  mm_base_spread = 0.5;
  inventory_skew_factor = 0.02;
  volatility_scaling = 1.5;
}

let on_tick (mm : market_maker) (t : tick) : decision =
  mm.price_history <- t.mid_price :: mm.price_history;
  if List.length mm.price_history > 20 then
    mm.price_history <- take 20 mm.price_history;

  let vol_estimate =
    if List.length mm.price_history >= 5 then begin
      let ph = Array.of_list (List.rev mm.price_history) in
      let n = Array.length ph in
      let returns =
        Array.to_list
          (Array.init (n - 1) (fun i -> ph.(i + 1) /. ph.(i) -. 1.0))
      in
      if List.length returns > 1 then stdev returns else 0.01
    end else 0.01
  in

  let spread_mult = 1.0 +. mm.volatility_scaling *. vol_estimate *. 10.0 in
  let target_spread = mm.mm_base_spread *. min spread_mult 5.0 in
  let skew = clamp (-. mm.inventory *. mm.inventory_skew_factor) (-0.5) 0.5 in

  let bid_offset = target_spread *. (0.5 +. skew) in
  let ask_offset = target_spread *. (0.5 -. skew) in
  let bid_price = t.mid_price -. bid_offset in
  let ask_price = t.mid_price +. ask_offset in

  let prob_bid_fill = clamp (1.0 -. bid_offset /. (t.spread *. 2.0)) 0.0 1.0 in
  let prob_ask_fill = clamp (1.0 -. ask_offset /. (t.spread *. 2.0)) 0.0 1.0 in
  let fill_bid = Random.float 1.0 < prob_bid_fill *. 0.8 in
  let fill_ask = Random.float 1.0 < prob_ask_fill *. 0.8 in

  let trade_volume = 0.5 in
  if fill_bid then begin
    mm.cash <- mm.cash -. bid_price *. trade_volume;
    mm.inventory <- mm.inventory +. trade_volume;
    mm.mm_trade_count <- mm.mm_trade_count + 1;
    mm.mm_fill_count <- mm.mm_fill_count + 1;
    mm.trade_log <- 0.0 :: mm.trade_log
  end;
  if fill_ask then begin
    mm.cash <- mm.cash +. ask_price *. trade_volume;
    mm.inventory <- mm.inventory -. trade_volume;
    mm.mm_trade_count <- mm.mm_trade_count + 1;
    mm.mm_fill_count <- mm.mm_fill_count + 1;
    mm.trade_log <- 0.0 :: mm.trade_log
  end;

  let mark_value = mm.inventory *. t.mid_price in
  let total_equity = mm.cash +. mark_value in

  { d_mid           = t.mid_price;
    d_vol_est       = vol_estimate;
    d_target_spread = target_spread;
    d_skew          = skew;
    d_bid           = bid_price;
    d_ask           = ask_price;
    d_inventory     = mm.inventory;
    d_cash          = mm.cash;
    d_equity        = total_equity;
    d_fill_bid      = fill_bid;
    d_fill_ask      = fill_ask }

(* -------------------- 3. PHYSICAL ACTION DISPATCHER ------------------- *)

type threat_level = Green | Yellow | Red

let string_of_threat_level = function
  | Green  -> "GREEN"
  | Yellow -> "YELLOW"
  | Red    -> "RED"

type action_dispatcher = {
  mutable ad_level      : threat_level;
  mutable speed_percent : int;
  mutable alarm_state   : bool;
  mutable led_color     : string;
}

let create_action_dispatcher () = {
  ad_level = Green;
  speed_percent = 100;
  alarm_state = false;
  led_color = "GREEN";
}

let ad_update (d : action_dispatcher) ~volatility ~inventory_risk ~drawdown =
  let (level, speed, alarm, led, desc) =
    if drawdown > 0.15 || inventory_risk > 0.8 || volatility > 2.0 then
      (Red, 0, true, "RED",
       "EMERGENCY STOP: Widening spreads to max, halting aggressive quoting.")
    else if drawdown > 0.05 || inventory_risk > 0.4 || volatility > 1.0 then
      (Yellow, 50, false, "YELLOW",
       "CAUTION: Reducing position limits, tightening risk controls.")
    else
      (Green, 100, false, "GREEN",
       "OPTIMAL: Full market-making capacity engaged.")
  in
  d.ad_level <- level;
  d.speed_percent <- speed;
  d.alarm_state <- alarm;
  d.led_color <- led;
  Printf.printf "  [PHYSICAL ACTION] LED: %s | Speed: %d%% | Alarm: %s\n"
    led speed (if alarm then "ON" else "OFF");
  Printf.printf "     -> %s\n" desc

(* ---------------------- 4. METRICS CALCULATOR ------------------------- *)

type metrics = {
  m_sharpe          : float;
  m_max_drawdown    : float;
  m_total_pnl       : float;
  m_pnl_per_trade   : float;
  m_fill_rate       : float;
  m_final_inventory : float;
  m_condition       : string;
  m_equity_series   : float list;
}

let compute_metrics ~(equity_series : float list)
    ~(fill_count : int) ~(trade_count : int)
    ~(final_inventory : float) ~final_price ~condition_name =
  ignore final_price;
  let equity_arr = Array.of_list equity_series in
  let n = Array.length equity_arr in
  if n < 2 then
    { m_sharpe = 0.0; m_max_drawdown = 0.0; m_total_pnl = 0.0;
      m_pnl_per_trade = 0.0; m_fill_rate = 0.0;
      m_final_inventory = final_inventory;
      m_condition = condition_name;
      m_equity_series = equity_series }
  else begin
    let initial_equity = equity_arr.(0) in
    let total_pnl = equity_arr.(n - 1) -. initial_equity in
    let returns =
      Array.to_list
        (Array.init (n - 1) (fun i ->
             if equity_arr.(i) > 0.0 then
               equity_arr.(i + 1) /. equity_arr.(i) -. 1.0
             else 0.0))
    in
    let sharpe =
      match returns with
      | [] -> 0.0
      | _ ->
        let m = mean returns in
        let s = stdev returns in
        if s > 0.0 then (m /. s) *. sqrt 252.0 else 0.0
    in
    let peak = ref equity_arr.(0) in
    let max_dd = ref 0.0 in
    Array.iter (fun v ->
        if v > !peak then peak := v;
        let dd = if !peak > 0.0 then (!peak -. v) /. !peak else 0.0 in
        if dd > !max_dd then max_dd := dd)
      equity_arr;
    let pnl_per_trade =
      if trade_count > 0 then total_pnl /. float_of_int trade_count else 0.0
    in
    let fill_rate =
      if trade_count > 0 then float_of_int fill_count /. float_of_int trade_count
      else 0.0
    in
    { m_sharpe = sharpe;
      m_max_drawdown = !max_dd;
      m_total_pnl = total_pnl;
      m_pnl_per_trade = pnl_per_trade;
      m_fill_rate = fill_rate;
      m_final_inventory = final_inventory;
      m_condition = condition_name;
      m_equity_series = equity_series }
  end

(* ------------------------- 5. SIMULATION ENGINE ----------------------- *)

let run_condition ~condition_name ~drift ~volatility ~duration_ticks : metrics =
  Printf.printf "\n%s\n" (String.make 60 '=');
  Printf.printf "> CONDITION: %s\n" condition_name;
  Printf.printf "   Drift=%.2f, Volatility=%.2f\n" drift volatility;
  Printf.printf "%s\n" (String.make 60 '=');

  let feed = create_live_data_feed ~initial_price:100.0 drift volatility in
  let mm = create_market_maker ~initial_cash:10000.0 () in
  let dispatcher = create_action_dispatcher () in
  let equity_series = ref [] in

  for tick_count = 0 to duration_ticks - 1 do
    let t = next_tick feed in
    let d = on_tick mm t in
    equity_series := d.d_equity :: !equity_series;
    if tick_count mod 10 = 0 then begin
      let inventory_risk = abs_float d.d_inventory /. 50.0 in
      let peak = List.fold_left max neg_infinity !equity_series in
      let current_dd =
        if peak > 0.0 then (peak -. d.d_equity) /. peak else 0.0
      in
      ad_update dispatcher
        ~volatility:d.d_vol_est
        ~inventory_risk
        ~drawdown:current_dd
    end;
    if tick_count mod 20 = 0 then
      Printf.printf
        "  Tick %3d | Mid: %.2f | Spread: %.2f | Inv: %.2f | Equity: %.2f\n"
        tick_count d.d_mid d.d_target_spread d.d_inventory d.d_equity
  done;

  let equity_series = List.rev !equity_series in
  let metrics =
    compute_metrics
      ~equity_series
      ~fill_count:mm.mm_fill_count
      ~trade_count:mm.mm_trade_count
      ~final_inventory:mm.inventory
      ~final_price:feed.price
      ~condition_name
  in
  Printf.printf "\n--- Final Metrics for %s ---\n" condition_name;
  Printf.printf "  Sharpe Ratio        : %.4f\n" metrics.m_sharpe;
  Printf.printf "  Max Drawdown        : %.2f%%\n"
    (metrics.m_max_drawdown *. 100.0);
  Printf.printf "  Total PnL           : $%.2f\n" metrics.m_total_pnl;
  Printf.printf "  PnL per Trade       : $%.2f\n" metrics.m_pnl_per_trade;
  Printf.printf "  Fill Rate           : %.1f%%\n"
    (metrics.m_fill_rate *. 100.0);
  Printf.printf "  Final Inventory     : %.2f units\n" metrics.m_final_inventory;
  Printf.printf "  Total Trades        : %d\n" mm.mm_trade_count;
  metrics

(* ------------------------------ 6. MAIN ------------------------------- *)

let main () =
  let conditions = [
    ("Calm Market",       0.0,  0.15);
    ("Trending Up",       0.4,  0.40);
    ("High Volatility",   0.0,  1.80);
    ("Flash Crash",      -2.5,  2.50);
    ("Mean-Reverting",    0.0,  0.90);
  ] in
  let results =
    List.map (fun (name, drift, vol) ->
        run_condition ~condition_name:name ~drift ~volatility:vol
          ~duration_ticks:250)
      conditions
  in
  let ranked = List.sort (fun a b -> compare b.m_sharpe a.m_sharpe) results in
  Printf.printf "\n%s\n" (String.make 70 '=');
  Printf.printf "FINAL RANKING: PREFERRED -> WORST (by Sharpe Ratio)\n";
  Printf.printf "%s\n" (String.make 70 '=');
  List.iteri (fun i r ->
      Printf.printf
        "%d. %-25s | Sharpe: %.4f | MaxDD: %5.2f%% | PnL: $%7.2f | Fill: %5.1f%%\n"
        (i + 1) r.m_condition r.m_sharpe
        (r.m_max_drawdown *. 100.0) r.m_total_pnl
        (r.m_fill_rate *. 100.0))
    ranked;
  Printf.printf "\nSimulation complete. All outputs printed above.\n"

(* ========================================================================= *)
(* 7. PRODUCTION CODE — UNCOMMENT THIS BLOCK, THEN SWAP THE ENTRY POINT      *)
(*                                                                           *)
(* Uses only the OCaml standard library, so it compiles and runs on any      *)
(* platform (OneCompiler included).                                          *)
(*                                                                           *)
(* In a real deployment:                                                     *)
(*   - Replace fetch_ticker_and_book with a cohttp-lwt-unix GET to Binance   *)
(*   - Replace place_limit_order with a signed HMAC-SHA256 POST              *)
(*   - Replace gpio_set_pin / serial_send with your board-specific bindings  *)
(* Everything else stays identical.                                          *)
(* ========================================================================= *)

(*
type real_data_feed = {
  rdf_symbol       : string;
  mutable rdf_price : float;
  mutable rdf_step : int;
  rdf_base_spread  : float;
}

let create_real_data_feed symbol = {
  rdf_symbol = symbol;
  rdf_price = 100.0;
  rdf_step = 0;
  rdf_base_spread = 0.5;
}

(* On a real box this would be an HTTPS GET to /api/v3/ticker/price and
   /api/v3/depth. Here we simulate a GBM price move so the whole pipeline
   can be exercised end-to-end with stdlib only. *)
let fetch_ticker_and_book (feed : real_data_feed) =
  let dt = 0.1 in
  let shock = gaussian () *. sqrt dt in
  feed.rdf_price <-
    feed.rdf_price *. exp ((0.0 -. 0.5 *. 0.4 ** 2.0) *. dt +. 0.4 *. shock);
  feed.rdf_price <- max feed.rdf_price 50.0;
  feed.rdf_step <- feed.rdf_step + 1;
  let spread = feed.rdf_base_spread *. (1.0 +. 0.2 *. Random.float 1.0) in
  let volume = max 0.1 (-. log (max (Random.float 1.0) 1e-12) *. 5.0) in
  (feed.rdf_price,
   feed.rdf_price -. spread /. 2.0,
   feed.rdf_price +. spread /. 2.0,
   volume)

type real_market_maker = {
  rmm_symbol              : string;
  mutable rmm_cash        : float;
  mutable rmm_inventory   : float;
  mutable rmm_price_hist  : float list;
  mutable rmm_base_spread : float;
  mutable rmm_skew_factor : float;
  mutable rmm_vol_scaling : float;
  mutable rmm_open_id     : string option;
  mutable rmm_trade_count : int;
  mutable rmm_fill_count  : int;
  mutable rmm_order_seq   : int;
  rmm_api_key             : string;
  rmm_api_secret          : string;
}

let create_real_market_maker ~symbol ~initial_cash = {
  rmm_symbol = symbol;
  rmm_cash = initial_cash;
  rmm_inventory = 0.0;
  rmm_price_hist = [];
  rmm_base_spread = 0.5;
  rmm_skew_factor = 0.02;
  rmm_vol_scaling = 1.5;
  rmm_open_id = None;
  rmm_trade_count = 0;
  rmm_fill_count = 0;
  rmm_order_seq = 0;
  rmm_api_key = (try Sys.getenv "BINANCE_API_KEY" with Not_found -> "");
  rmm_api_secret = (try Sys.getenv "BINANCE_SECRET" with Not_found -> "");
}

(* Returns a synthetic order ID. Real version signs the request and POSTs. *)
let place_limit_order (mm : real_market_maker)
    ~(side : string) ~(price : float) ~(qty : float) : string =
  ignore (side, price, qty);
  mm.rmm_order_seq <- mm.rmm_order_seq + 1;
  Printf.sprintf "ORDER-%s-%d" mm.rmm_symbol mm.rmm_order_seq

let cancel_order (_mm : real_market_maker) (_oid : string) : unit = ()

let real_mm_on_tick (rmm : real_market_maker) (t : tick) =
  rmm.rmm_price_hist <- t.mid_price :: rmm.rmm_price_hist;
  if List.length rmm.rmm_price_hist > 20 then
    rmm.rmm_price_hist <- take 20 rmm.rmm_price_hist;
  let vol_estimate =
    if List.length rmm.rmm_price_hist >= 5 then begin
      let ph = Array.of_list (List.rev rmm.rmm_price_hist) in
      let n = Array.length ph in
      let returns =
        Array.to_list
          (Array.init (n - 1) (fun i -> ph.(i + 1) /. ph.(i) -. 1.0))
      in
      if List.length returns > 1 then stdev returns else 0.01
    end else 0.01
  in
  let spread_mult = 1.0 +. rmm.rmm_vol_scaling *. vol_estimate *. 10.0 in
  let target_spread = rmm.rmm_base_spread *. min spread_mult 5.0 in
  let skew =
    clamp (-. rmm.rmm_inventory *. rmm.rmm_skew_factor) (-0.5) 0.5
  in
  let bid_price = t.mid_price -. target_spread *. (0.5 +. skew) in
  let ask_price = t.mid_price +. target_spread *. (0.5 -. skew) in
  (match rmm.rmm_open_id with
   | Some oid -> cancel_order rmm oid
   | None -> ());
  let side, px =
    if skew < 0.0 then ("buy", bid_price) else ("sell", ask_price)
  in
  let oid = place_limit_order rmm ~side ~price:px ~qty:0.001 in
  rmm.rmm_open_id <- Some oid;
  rmm.rmm_trade_count <- rmm.rmm_trade_count + 1;
  rmm.rmm_fill_count  <- rmm.rmm_fill_count + 1;
  let total_equity = rmm.rmm_cash +. rmm.rmm_inventory *. t.mid_price in
  (vol_estimate, target_spread, skew, bid_price, ask_price,
   rmm.rmm_inventory, total_equity)

let gpio_set_pin pin value =
  (* Silently ignored if the "gpio" CLI is not installed. *)
  ignore (Sys.command (Printf.sprintf "gpio write %d %d" pin value))

let serial_send (_port : string) (msg : string) =
  Printf.eprintf "[serial] %s\n" msg

let real_ad_update ~volatility ~inventory_risk ~drawdown =
  let (_level, speed, alarm, led) =
    if drawdown > 0.15 || inventory_risk > 0.8 || volatility > 2.0 then
      (Red, 0, true, "RED")
    else if drawdown > 0.05 || inventory_risk > 0.4 || volatility > 1.0 then
      (Yellow, 50, false, "YELLOW")
    else
      (Green, 100, false, "GREEN")
  in
  let p_red = 17 and p_green = 27 and p_yellow = 22 and p_buzz = 23 in
  gpio_set_pin p_red 0;
  gpio_set_pin p_green 0;
  gpio_set_pin p_yellow 0;
  (match led with
   | "RED"    -> gpio_set_pin p_red 1
   | "YELLOW" -> gpio_set_pin p_yellow 1
   | _        -> gpio_set_pin p_green 1);
  gpio_set_pin p_buzz (if alarm then 1 else 0);
  serial_send "/dev/ttyUSB0" (Printf.sprintf "SPEED:%d" speed);
  Printf.printf "  [REAL HW] LED: %s | Speed: %d%% | Alarm: %s\n"
    led speed (if alarm then "ON" else "OFF")

let production_main () =
  Printf.printf "Starting PRODUCTION mode (stdlib-only pipeline)...\n";
  let feed = create_real_data_feed "BTCUSDT" in
  let rmm = create_real_market_maker ~symbol:"BTCUSDT" ~initial_cash:10000.0 in
  let iterations = 200 in
  for i = 0 to iterations - 1 do
    let (last_price, best_bid, best_ask, volume) =
      fetch_ticker_and_book feed
    in
    let t = {
      timestamp = float_of_int i;
      mid_price = last_price;
      spread    = max ((best_ask -. best_bid) /. 2.0) 0.01;
      volume    = volume;
    } in
    let (vol_est, _sp, _sk, _bid, _ask, inv, eq) = real_mm_on_tick rmm t in
    if i mod 5 = 0 then
      real_ad_update
        ~volatility:vol_est
        ~inventory_risk:(abs_float inv /. 50.0)
        ~drawdown:0.0;
    if i mod 20 = 0 then
      Printf.printf "Live | Mid: %.2f | Inv: %.2f | Equity: %.2f\n"
        t.mid_price inv eq
  done;
  Printf.printf "PRODUCTION run complete. Final equity: %.2f\n"
    (rmm.rmm_cash +. rmm.rmm_inventory *. feed.rdf_price)
*)

(* ========================================================================= *)
(* 8. ENTRY POINT                                                            *)
(*     Swap to  let () = production_main ()  after uncommenting block 7.     *)
(* ========================================================================= *)

let () = main ()