(* Type check and elaborate ABS to CIL *)
module A = Cabs
module E = Errormsg
module H = Hashtbl

open Cabs
open Pretty
open Cil
open Trace


(* ---------- source error message handling ------------- *)
let lu = locUnknown
let cabslu = {lineno = -10; filename = "cabs lu";}

(* these return 'a (alpha) because they throw exceptions, so can be used in any context *)
(*
let sourceErrorLoc (loc : Cil.location) (s : string) : 'a =
begin
  (E.s (error "%s[%d]:%s" loc.file loc.line s))
end

let sourceError (s : string) : 'a =
begin
  (sourceErrorLoc !currentLoc s)
end


let sourceWarLoc (loc : Cil.location) (s : string) : 'a =
begin
  (E.s (error "%s[%d]:%s" loc.file loc.line s))
end


let sourceWar (s : string) : 'a =
begin
  (sourceWarLoc !currentLoc s)
end

let logWarLoc (loc : Cil.location) (s : string) : 'a =
begin
  (ignore (E.log "%s[%d]:%s" loc.file loc.line s))
end


let logWarning (s : string) : 'a =
begin
  (logWarLoc !currentLoc s)
end


let warnLoc (loc : Cil.location) (s : string) : 'a =
begin
  (ignore (E.warn "%s[%d]:%s" loc.file loc.line s))
end


let giveWarn (s : string) : 'a =
begin
  (warnLoc !currentLoc s)
end


let sourceUnimpLoc (loc : Cil.location) (s : string) : 'a =
begin
  (E.s (error "%s:%d :%s" loc.file loc.line s))
end


let sourceUnimp (s : string) : 'a =
begin
  (sourceUnimpLoc !currentLoc s)
end
*)  

let convLoc (l : cabsloc) =
   {line = l.lineno; file = l.filename;}


(*** EXPRESSIONS *************)
                                        (* We collect here the program *)
let theFile : global list ref = ref []

(********* ENVIRONMENTS ***************)

(* The environment is kept in two distinct data structures. A hash table maps
 * each original variable name into a varinfo (for variables, or an
 * enumeration tag, or a type). (Note that the varinfo might contain an
 * alpha-converted name different from that of the lookup name.) The Ocaml
 * hash tables can keep multiple mappings for a single key. Each time the
 * last mapping is returned and upon deletion the old mapping is restored. To
 * keep track of local scopes we also maintain a list of scopes (represented
 * as lists).  *)
type envdata =
    EnvVar of varinfo                   (* The name refers to a variable
                                         * (which could also be a function) *)
  | EnvEnum of exp * typ                (* The name refers to an enumeration
                                         * tag for which we know the value
                                         * and the host type *)
  | EnvTyp of typ                       (* The name is of the form  "struct
                                         * foo", or "union foo" or "enum foo"
                                         * and refers to a type. Note that
                                         * the name of the actual type might
                                         * be different from foo due to alpha
                                         * conversion *)


let env : (string, envdata * location) H.t = H.create 307

 (* In the scope we keep the original name, so we can remove them from the
  * hash table easily *)
type undoScope =
    UndoRemoveFromEnv of string
  | UndoResetAlphaCounter of string * int
  | UndoRemoveFromAlphaTable of string

let scopes :  undoScope list ref list ref = ref []


(* When you add to env, you also add it to the current scope *)
let addLocalToEnv (n: string) (d: envdata) = 
  H.add env n (d, !currentLoc);
    (* If we are in a scope, then it means we are not at top level. Add the 
     * name to the scope *)
  (match !scopes with
    [] -> begin
      match d with
        EnvVar _ -> 
          E.s (E.bug "addLocalToEnv: not in a scope when adding %s!" n)
      | _ -> () (* We might add types *)
    end
  | s :: _ -> 
      s := (UndoRemoveFromEnv n) :: !s)


let addGlobalToEnv (k: string) (d: envdata) : unit = 
  H.add env k (d, !currentLoc)
  
  

(* Create a new name based on a given name. The new name is formed from a 
 * prefix (obtained from the given name as the longest prefix that ends with 
 * a non-digit), followed by a '_' and then by a positive integer suffix. The 
 * first argument is a table mapping name prefixes with the largest suffix 
 * used so far for that prefix. The largest suffix is one when only the 
 * version without suffix has been used. *)
let alphaTable : (string, int ref) H.t = H.create 307 (* vars and enum tags. 
                                                       * For composite types 
                                                       * we have names like 
                                                       * "struct foo" or 
                                                       * "union bar" *)

(* To keep different name scopes different, we add prefixes to names 
 * specifying the kind of name: the kind can be one of "" for variables or 
 * enum tags, "struct" for structures, "enum" for enumerations, "union" for 
 * union types, or "type" for types *)
let kindPlusName (kind: string)
                 (origname: string) : string =
  if kind = "" then origname else
  kind ^ " " ^ origname
                   
let newAlphaName (globalscope: bool) (* The name should have global scope *)
                 (kind: string) 
                 (origname: string) : string = 
  let lookupname = kindPlusName kind origname in
  (* If we are in a scope then it means that we are alpha-converting a local 
   * name. Go and add stuff to reset the state of the alpha table but only to 
   * the top-most scope (that of the enclosing function) *)
  let rec findEnclosingFun = function
      [] -> (* At global scope *)()
    | [s] -> begin
        let prefix, _, _ = splitNameForAlpha lookupname in
        try
          let countref = H.find alphaTable prefix in
          s := (UndoResetAlphaCounter (prefix, !countref)) :: !s
        with Not_found ->
          s := (UndoRemoveFromAlphaTable prefix) :: !s
    end
    | _ :: rest -> findEnclosingFun rest
  in
  if not globalscope then 
    findEnclosingFun !scopes;

  let newname = Cil.newAlphaName alphaTable lookupname in

  let l = String.length lookupname in
  let n' = 
    let l = 1 + String.length kind in
    if l > 1 then 
      String.sub newname l (String.length newname - l)
    else
      newname
  in
  n'
  
let structId = ref 0
let anonStructName n = 
  incr structId;
  "__anon" ^ n ^ (string_of_int (!structId))




let localId = ref (-1)   (* All locals get id's starting at 0 *)
let locals : varinfo list ref = ref []

let resetLocals () = 
  localId := (-1); locals := []

let startFile () = 
  H.clear env;
  H.clear alphaTable;
  resetLocals ()


     (* Eliminate all locals from the alphaTable. Return the maxlocal id and 
      * the list of locals (but remove the arguments first) *)
let endFunction (formals: varinfo list) : (int * varinfo list) = 
  let rec loop revlocals = function
      [] -> revlocals
    | lvi :: t -> (* H.remove alphaTable lvi.vname; *) 
        loop (lvi :: revlocals) t
  in
  let revlocals = loop [] !locals in
  let maxid = !localId + 1 in
  resetLocals ();
  let rec drop formals locals = 
    match formals, locals with
      [], l -> l
    | f :: formals, l :: locals -> 
        if f != l then 
          E.s (error "formals are not in locals");
        drop formals locals
    | _ -> E.s (error "Too few locals")
  in
  (maxid, drop formals revlocals)

let enterScope () = 
  scopes := (ref []) :: !scopes

     (* Exit a scope and clean the environment. We do not yet delete from 
      * the name table *)
let exitScope () = 
  let this, rest = 
    match !scopes with
      car :: cdr -> car, cdr
    | [] -> E.s (error "Not in a scope")
  in
  scopes := rest;
  let rec loop = function
      [] -> ()
    | UndoRemoveFromEnv n :: t -> 
        H.remove env n; loop t
    | UndoRemoveFromAlphaTable n :: t -> H.remove alphaTable n; loop t
    | UndoResetAlphaCounter (n, oldv) :: t -> 
        begin
          try
            let vref = H.find alphaTable n in
            vref := oldv
          with Not_found -> ()
        end;
        loop t
  in
  loop !this

(* Lookup a variable name. Return also the location of the definition. Might 
 * raise Not_found  *)
let lookupVar (n: string) : varinfo * location = 
  match H.find env n with
    (EnvVar vi), loc -> vi, loc
  | _ -> raise Not_found
        
let docEnv () = 
  let acc : (string * (envdata * location)) list ref = ref [] in
  let doone () = function
      EnvVar vi, l -> 
        dprintf "Var(%s,global=%b) (at %a)" vi.vname vi.vglob d_loc l
    | EnvEnum (tag, typ), l -> dprintf "Enum (at %a)" d_loc l
    | EnvTyp t, l -> text "typ"
  in
  H.iter (fun k d -> acc := (k, d) :: !acc) env;
  docList line (fun (k, d) -> dprintf "  %s -> %a" k doone d) () !acc


(* Create a new variable ID *)
let newVarId name isglobal = 
  if isglobal then H.hash name
  else begin
    incr localId;
    !localId
  end



(* Add a new variable. Do alpha-conversion if necessary *)
let alphaConvertVarAndAddToEnv (addtoenv: bool) (vi: varinfo) : varinfo = 
  let newname = newAlphaName (addtoenv && vi.vglob) "" vi.vname in
  let newvi = 
    if vi.vname = newname then vi else 
    {vi with vname = newname; 
             vid = if vi.vglob then H.hash newname else vi.vid} in
  if not vi.vglob then
    locals := newvi :: !locals;

  (if addtoenv then 
    if vi.vglob then
      addGlobalToEnv vi.vname (EnvVar newvi)
    else
      addLocalToEnv vi.vname (EnvVar newvi));
  (* ignore (E.log "After adding %s alpha table is: %t\n"
            newvi.vname docAlphaTable); *)
  newvi


(* Create a new temporary variable *)
let newTempVar typ = 
  (* Strip the "const" from the type. It is unfortunate that const variables 
    can only be set in initialization. Once we decided to move all 
    declarations to the top of the functions, we have no way of setting a 
    "const" variable *)
  let stripConst t =
    let a = typeAttrs t in
    setTypeAttrs t 
      (dropAttribute (dropAttribute a (Attr("const", [])))
         (Attr("restrict", [])))
  in
  alphaConvertVarAndAddToEnv false  (* Do not add to the environment *)
    { vname = "tmp";  (* addNewVar will make the name fresh *)
      vid   = newVarId "tmp" false;
      vglob = false;
      vtype = stripConst typ;
      vdecl = locUnknown;
      vattr = [];
      vaddrof = false;
      vreferenced = false;   (* sm *)
      vstorage = NoStorage;
    } 


let mkAddrOfAndMark ((b, off) as lval) : exp = 
  (* Mark the vaddrof flag if b is a variable *)
  (match b with 
    Var vi -> vi.vaddrof <- true
  | _ -> ());
  mkAddrOf lval
  


   (* Keep a set of self compinfo for composite types *)
let compInfoNameEnv : (string, compinfo) H.t = H.create 113

let lookupTypeNoError (kind: string) 
                      (n: string) : typ * location = 
  let kn = kindPlusName kind n in
  match H.find env kn with
    EnvTyp t, l -> t, l
  | _ -> raise Not_found

let lookupType (kind: string) 
               (n: string) : typ * location = 
  try
    lookupTypeNoError kind n
  with Not_found -> 
    E.s (error "Cannot find type %s (kind:%s)\n" n kind)

(* Create the self ref cell and add it to the map *)
let createCompInfo (iss: bool) (n: string) : compinfo = 
  (* Add to the self cell set *)
  let key = (if iss then "struct " else "union ") ^ n in
  try
    H.find compInfoNameEnv key (* Only if not already in *)
  with Not_found -> begin
    (* Create a compinfo *)
    let res = mkCompInfo iss n (fun _ -> []) [] in
    H.add compInfoNameEnv key res;
    res
  end

   (* kind is either "struct" or "union" or "enum" and n is a name *)
let findCompType kind n a = 
  let key = kind ^ " " ^ n in
  let makeForward () = 
    (* This is a forward reference, either because we have not seen this 
     * struct already or because we want to create a version with different 
     * attributes  *)
    let iss =  (* is struct or union *)
      if kind = "enum" then E.s (error "Forward reference for enum %s" n)
      else if kind = "struct" then true else false
    in
    let self = createCompInfo iss n in
    TComp (true, self, a)
  in
  try
    let old, _ = lookupTypeNoError kind n in (* already defined  *)
    let olda = typeAttrs old in
    if olda = a then old else makeForward ()
  with Not_found -> makeForward ()
  
  

(**** To initialize some local arrays we need strncpy ****)
let strncpyFun = 
  let fdec = emptyFunction "strncpy" in
  let argd  = makeLocalVar fdec "dst" charPtrType in
  let args  = makeLocalVar fdec "src" charConstPtrType in
  let arglen  = makeLocalVar fdec "len" uintType in
  fdec.svar.vtype <- TFun(charPtrType, [ argd; args; arglen ], false, []);
  fdec

let explodeString (nullterm: bool) (s: string) : char list =  
  let rec allChars i acc = 
    if i < 0 then acc
    else allChars (i - 1) ((String.get s i) :: acc)
  in
  allChars (-1 + String.length s) 
    (if nullterm then [Char.chr 0] else [])
    
(*** In order to process GNU_BODY expressions we must record that a given 
 *** COMPUTATION is interesting *)
let gnu_body_result : (A.statement * ((exp * typ) option ref)) ref 
    = ref (A.NOP cabslu, ref None)

(*** When we do statements we need to know the current return type *)
let currentReturnType : typ ref = ref (TVoid([]))
let currentFunctionVI : varinfo ref = ref dummyFunDec.svar

(**** Occasionally we see structs with no name and no fields *)


module BlockChunk = 
  struct
    type chunk = {
        stmts: stmt list;
        postins: instr list;              (* Some instructions to append at 
                                           * the ends of statements (in 
                                           * reverse order)  *)
                                        (* A list of case statements at the 
                                         * outer level *)
        cases: (label * stmt) list
      } 

    let empty = 
      { stmts = []; postins = []; cases = [];
        (* fixbreak = (fun _ -> ()); fixcont = (fun _ -> ()) *) }

    let isEmpty (c: chunk) = 
      c.postins == [] && c.stmts == []

    let isNotEmpty (c: chunk) = not (isEmpty c)

    let i2c (i: instr) = 
      { empty with postins = [i] }
        
    (* Occasionally, we'll have to push postins into the statements *)
    let pushPostIns (c: chunk) : stmt list = 
      if c.postins = [] then c.stmts
      else
        let rec toLast = function
            [{skind=Instr il} as s] as stmts -> 
              s.skind <- Instr (il @ (List.rev c.postins));
              stmts

          | [] -> [mkStmt (Instr (List.rev c.postins))]

          | a :: rest -> a :: toLast rest
        in
        compactBlock (toLast c.stmts)


    (* Add an instruction at the end. Never refer to this instruction again 
     * after you call this *)
    let (+++) (c: chunk) (i : instr) =
      {c with postins = i :: c.postins}

    (* Append two chunks. Never refer to the original chunks after you call 
     * this. And especially never share c2 with somebody else *)
    let (@@) (c1: chunk) (c2: chunk) = 
      { stmts = compactBlock (pushPostIns c1 @ c2.stmts);
        postins = c2.postins;
        cases = c1.cases @ c2.cases;
      } 

    let skipChunk = empty
        
    let returnChunk (e: exp option) (l: location) : chunk = 
      { stmts = [ mkStmt (Return(e, l)) ];
        postins = [];
        cases = []
      }

    let ifChunk (be: exp) (l: location) (t: chunk) (e: chunk) : chunk = 
      
      { stmts = [ mkStmt(If(be, pushPostIns t, pushPostIns e, l))];
        postins = [];
        cases = t.cases @ e.cases;
      } 

    let canDuplicate (c: chunk) = 
                        (* We can duplicate a statement if it is small and 
                         * does not contain label definitions  
      let rec cost = function
          [] -> 0
        | s :: rest -> 
            let one = 
              if s.labels <> [] then 100 else
              match s.skind with
                Instr il -> List.length il
              | Goto _ | Return _ -> 1
              | _ -> 100
            in
            one + cost rest
      in
      cost c.stmts + List.length c.postins <= 3
                           *)
      false (* Do not duplicate because we get too much sharing *)

    let canDrop (c: chunk) = false

    let loopChunk (body: chunk) : chunk = 
      (* Make the statement *)
      let loop = mkStmt (Loop (pushPostIns body, !currentLoc)) in
      { stmts = [ loop (* ; n *) ];
        postins = [];
        cases = body.cases;
      } 
      
    let breakChunk (l: location) : chunk = 
      { stmts = [ mkStmt (Break l) ];
        postins = [];
        cases = [];
      } 
      
    let continueChunk (l: location) : chunk = 
      { stmts = [ mkStmt (Continue l) ];
        postins = [];
        cases = []
      } 

        (* Keep track of the gotos *)
    let backPatchGotos : (string, stmt ref list ref) H.t = H.create 17
    let addGoto (lname: string) (bref: stmt ref) : unit = 
      let gotos = 
        try
          H.find backPatchGotos lname
        with Not_found -> begin
          let gotos = ref [] in
          H.add backPatchGotos lname gotos;
          gotos
        end
      in
      gotos := bref :: !gotos

        (* Keep track of the labels *)
    let labelStmt : (string, stmt) H.t = H.create 17
    let initLabels () = 
      H.clear backPatchGotos;
      H.clear labelStmt
      
    let resolveGotos () = 
      H.iter
        (fun lname gotos ->
          try
            let dest = H.find labelStmt lname in
            List.iter (fun gref -> gref := dest) !gotos
          with Not_found -> begin
            E.s (error "Label %s not found\n" lname)
          end)
        backPatchGotos

        (* Get the first statement in a chunk. Might need to change the 
         * statements in the chunk *)
    let getFirstInChunk (c: chunk) : stmt * block = 
      (* Get the first statement and add the label to it *)
      match c.stmts with
        s :: _ -> s, c.stmts
      | [] -> (* Add a statement *)
          let n = mkEmptyStmt () in
          n, n :: c.stmts
      
    let consLabel (l: string) (c: chunk) : chunk = 
      (* Get the first statement and add the label to it *)
      let labstmt, stmts' = getFirstInChunk c in
      (* Add the label *)
      labstmt.labels <- Label (l, !currentLoc) :: labstmt.labels;
      H.add labelStmt l labstmt;
      if c.stmts == stmts' then c else {c with stmts = stmts'}

    let gotoChunk (ln: string) (l: location) : chunk = 
      let gref = ref dummyStmt in
      addGoto ln gref;
      { stmts = [ mkStmt (Goto (gref, l)) ];
        postins = [];
        cases = [];
      }

    let caseChunk (e: exp) (l: location) (next: chunk) = 
      let fst, stmts' = getFirstInChunk next in
      let lb = Case (e, l) in
      fst.labels <- lb :: fst.labels;
      { next with stmts = stmts'; cases = (lb, fst) :: next.cases}
        
    let defaultChunk (l: location) (next: chunk) = 
      let fst, stmts' = getFirstInChunk next in
      let lb = Default l in
      fst.labels <- lb :: fst.labels;
      { next with stmts = stmts'; cases = (lb, fst) :: next.cases}

        
    let switchChunk (e: exp) (body: chunk) (l: location) =
      (* Make the statement *)
      let switch = mkStmt (Switch (e, pushPostIns body, 
                                   List.map (fun (_, s) -> s) body.cases, 
                                   l)) in
      { stmts = [ switch (* ; n *) ];
        postins = [];
        cases = [];
      } 

    let mkFunctionBody (c: chunk) : block = 
      resolveGotos (); initLabels ();
      if c.cases <> [] then
        E.s (error "Switch cases not inside a switch statement\n");
      pushPostIns c
      
  end

open BlockChunk 


(************ Labels ***********)
(* Since we turn dowhile and for loops into while we need to take care in 
 * processing the continue statement. For each loop that we enter we place a 
 * marker in a list saying what kinds of loop it is. When we see a continue 
 * for a Non-while loop we must generate a label for the continue *)
type loopstate = 
    While
  | NotWhile of string ref

let continues : loopstate list ref = ref []

let startLoop iswhile = 
  continues := (if iswhile then While else NotWhile (ref "")) :: !continues

let labelId = ref 0
let continueOrLabelChunk (l: location) : chunk = 
  match !continues with
    [] -> E.s (error "continue not in a loop")
  | While :: _ -> continueChunk l
  | NotWhile lr :: _ -> 
      if !lr = "" then begin
        incr labelId;
        lr := "Cont" ^ (string_of_int !labelId)
      end;
      gotoChunk !lr l

let consLabContinue (c: chunk) = 
  match !continues with
    [] -> E.s (error "labContinue not in a loop")
  | While :: rest -> c
  | NotWhile lr :: rest -> if !lr = "" then c else consLabel !lr c

let exitLoop () = 
  match !continues with
    [] -> E.s (error "exit Loop not in a loop")
  | _ :: rest -> continues := rest
      

(**** EXP actions ***)
type expAction = 
    ADrop                               (* Drop the result. Only the 
                                         * side-effect is interesting *)
  | ASet of lval * typ                  (* Put the result in a given lval, 
                                         * provided it matches the type  *)
  | AExp of typ option                  (* Return the exp as usual. 
                                         * Optionally we can specify an 
                                         * expected type. This is useful for 
                                         * constants *)


(******** CASTS *********)
let integralPromotion (t : typ) : typ = (* c.f. ISO 6.3.1.1 *)
  match unrollType t with
          (* We assume that an IInt can hold even an IUShort *)
    TInt ((IShort|IUShort|IChar|ISChar|IUChar), a) -> TInt(IInt, a)
  | TInt _ -> t
  | TEnum (_, _, a) -> TInt(IInt, a)
  | TBitfield((IShort|IChar|ISChar), _, a) -> TInt(IInt, a)
  | TBitfield((IUShort|IUChar), _, a) -> TInt(IUInt, a)
  | TBitfield(i, _, a) -> TInt(ILong, a)
  | _ -> E.s (error "integralPromotion")
  

let arithmeticConversion    (* c.f. ISO 6.3.1.8 *)
    (t1: typ)
    (t2: typ) : typ = 
  let checkToInt _ = () in  (* dummies for now *)
  let checkToFloat _ = () in
  match unrollType t1, unrollType t2 with
    TFloat(FLongDouble, _), _ -> checkToFloat t2; t1
  | _, TFloat(FLongDouble, _) -> checkToFloat t1; t2
  | TFloat(FDouble, _), _ -> checkToFloat t2; t1
  | _, TFloat (FDouble, _) -> checkToFloat t1; t2
  | TFloat(FFloat, _), _ -> checkToFloat t2; t1
  | _, TFloat (FFloat, _) -> checkToFloat t1; t2
  | _, _ -> begin
      let t1' = integralPromotion t1 in
      let t2' = integralPromotion t2 in
      match unrollType t1', unrollType t2' with
        TInt(IULongLong, _), _ -> checkToInt t2'; t1'
      | _, TInt(IULongLong, _) -> checkToInt t1'; t2'
            
      (* We assume a long long is always larger than a long  *)
      | TInt(ILongLong, _), _ -> checkToInt t2'; t1'  
      | _, TInt(ILongLong, _) -> checkToInt t1'; t2'
            
      | TInt(IULong, _), _ -> checkToInt t2'; t1'
      | _, TInt(IULong, _) -> checkToInt t1'; t2'

                    
      | TInt(ILong,_), TInt(IUInt,_) when not !ilongFitsUInt -> TInt(IULong,[])
      | TInt(IUInt,_), TInt(ILong,_) when not !ilongFitsUInt -> TInt(IULong,[])
            
      | TInt(ILong, _), _ -> checkToInt t2'; t1'
      | _, TInt(ILong, _) -> checkToInt t1'; t2'

      | TInt(IUInt, _), _ -> checkToInt t2'; t1'
      | _, TInt(IUInt, _) -> checkToInt t1'; t2'
            
      | TInt(IInt, _), TInt (IInt, _) -> t1'

      | _, _ -> E.s (error "arithmeticConversion")
  end

let conditionalConversion (e2: exp) (t2: typ) (e3: exp) (t3: typ) : typ =
  let tresult =  (* ISO 6.5.15 *)
    match unrollType t2, unrollType t3 with
      (TInt _ | TEnum _ | TBitfield _ | TFloat _), 
      (TInt _ | TEnum _ | TBitfield _ | TFloat _) -> 
        arithmeticConversion t2 t3 
    | TComp (_, comp2,_), TComp (_, comp3,_) 
          when comp2.ckey = comp3.ckey -> t2 
    | TPtr(_, _), TPtr(TVoid _, _) -> t2
    | TPtr(TVoid _, _), TPtr(_, _) -> t3
    | TPtr(t2'', _), TPtr(t3'', _) 
          when typeSig t2'' = typeSig t3'' -> t2
    | TPtr(_, _), TInt _ when 
            (match e3 with Const(CInt(0,_,_)) -> true | _ -> false) -> t2
    | TInt _, TPtr _ when 
              (match e2 with Const(CInt(0,_,_)) -> true | _ -> false) -> t3
    | _, _ -> E.s (error "A.QUESTION for non-scalar type")
  in
  tresult

  
let rec castTo (ot : typ) (nt : typ) (e : exp) : (typ * exp ) = 
  if typeSig ot = typeSig nt then (ot, e) else
  match ot, nt with
    TNamed(_,r, _), _ -> castTo r nt e
  | _, TNamed(_,r, _) -> castTo ot r e
  | TInt(ikindo,_), TInt(ikindn,_) -> 
      (nt, if ikindo == ikindn then e else doCastT e ot nt)

  | TPtr (told, _), TPtr(tnew, _) -> (nt, doCastT e ot nt)

  | TInt _, TPtr _ when
      (match e with Const(CInt(0,_,_)) -> true | _ -> false) -> 
        (nt, doCastT e ot nt)

  | TInt _, TPtr _ -> (nt, doCastT e ot nt)

  | TPtr _, TInt _ -> (nt, doCastT e ot nt)

  | TArray _, TPtr _ -> (nt, doCastT e ot nt)

  | TArray(t1,_,_), TArray(t2,None,_) when typeSig t1 = typeSig t2 -> (nt, e)

  | TPtr _, TArray(_,_,_) -> (nt, e)

  | TEnum _, TInt _ -> (nt, e)
  | TFloat _, TInt _ -> (nt, doCastT e ot nt)
  | TInt _, TFloat _ -> (nt, doCastT e ot nt)
  | TFloat _, TFloat _ -> (nt, doCastT e ot nt)
  | TInt _, TEnum _ -> (nt, e)
  | TEnum _, TEnum _ -> (nt, e)

  | TBitfield _, (TInt _ | TEnum _ | TBitfield _)-> (nt, e)
  | (TInt _ | TEnum _), TBitfield _ -> (nt, e)


    (* The expression is evaluated for its side-effects *)
  | (TInt _ | TEnum _ | TBitfield _ | TPtr _ ), TVoid _ -> (ot, e)

  | _ -> E.s (error "cabs2cil: castTo %a -> %a@!" d_type ot d_type nt)

(* A cast that is used for conditional expressions. Pointers are Ok *)
let checkBool (ot : typ) (e : exp) : bool =
  match unrollType ot with
    TInt _ -> true
  | TPtr _ -> true
  | TEnum _ -> true
  | TBitfield _ -> true
  | TFloat _ -> true
  |  _ -> E.s (error "castToBool %a" d_type ot)


(* Do types *)
(* Process a name group. Since this should work for both A.name and 
 * A.init_name we make it polymorphic *)
let doNameGroup (doone: A.spec_elem list -> 'n -> 'a) 
                ((s:A.spec_elem list), (nl:'n list)) : 'a list =
  List.map (fun n -> doone s n) nl



(* Create and cache varinfo's for globals. Returns the varinfo and whether 
 * there exists already a definition *)
let makeGlobalVarinfo (vi: varinfo) : varinfo * bool =
  try (* See if already defined *)
    let oldvi, oldloc = lookupVar vi.vname in
    (* It was already defined. We must reuse the varinfo. But clean up the 
     * storage.  *)
    let _ = 
      if vi.vstorage = oldvi.vstorage then ()
      else if vi.vstorage = Extern then ()
      else if oldvi.vstorage = Extern then 
        oldvi.vstorage <- vi.vstorage 
      else E.s (error "Redefinition of %s. Previous definitionon: %a" 
                  vi.vname d_loc oldloc)
    in
    (* Union the attributes *)
    oldvi.vattr <- addAttributes oldvi.vattr vi.vattr;
    (* Maybe we had an incomplete type before and it is complete now  *)
    let _ = 
      let oldts = typeSig oldvi.vtype in
      let newts = typeSig vi.vtype in
      if oldts = newts then ()
      else 
        match oldts, newts with
                                        (* If the new type is complete, I'll 
                                         * trust it  *)
        | TSArray(_, Some _, _), TSArray(_, None, _) -> ()
        | TSArray(_, _, _), TSArray(_, Some _, _) 
          -> oldvi.vtype <- vi.vtype
         (* If one is a function with no arguments and the other has some 
          * arguments, believe the one with the arguments *)
        | TSFun(_, [], va1, _), TSFun(r2, _ :: _, va2, a2)
               when va1 = va2 -> oldvi.vtype <- vi.vtype
        | TSFun(r1, _ , va1, _), TSFun(_, [], va2, a2) when va1 = va2 -> ()
        | _, _ -> E.s (error "Declaration of %s does not match previous declaration.@!Before=%a(%a)@!Now= %a (%t)@!" 
                         vi.vname d_plaintype oldvi.vtype 
                         d_loc oldloc
                         d_plaintype vi.vtype d_thisloc)
    in
    let rec alreadyDef = ref false in
    let rec loop = function
        [] -> []
      | (GVar (vi', i', l) as g) :: rest when vi'.vid = vi.vid -> 
          if i' = None then
            GDecl (vi', l) :: loop rest
          else begin
            alreadyDef := true;
            g :: rest (* No more defs *)
          end
      | g :: rest -> g :: loop rest
    in
    theFile := loop !theFile;
    oldvi, !alreadyDef
      
  with Not_found -> begin (* A new one. It is a definition unless it is 
                           * Extern  *)

    alphaConvertVarAndAddToEnv true vi, false
  end 

(**** PEEP-HOLE optimizations ***)
let afterConversion (c: chunk) : chunk = 
  (* Now scan the statements and find Instr blocks *)
  let collapseCallCast = function
      Call(Some(vi, false), f, args, l),
      Set((Var destv, NoOffset), 
                CastE (newt, Lval(Var vi', NoOffset)), _) 
      when (not vi.vglob && 
            String.length vi.vname >= 3 &&
            String.sub vi.vname 0 3 = "tmp" &&
            vi' == vi) 
      -> Some [Call(Some(destv, true), f, args, l)]
    | _ -> None
  in
  (* First add in the postins *)
  let sl = pushPostIns c in
  peepHole2 collapseCallCast sl;
  { c with stmts = sl; postins = [] }


(****** TYPE SPECIFIERS *******)
let rec doSpecList (specs: A.spec_elem list) 
       (* Returns the base type, the storage, whether it is inline and the 
        * (unprocessed) attributes *)
    : typ * storage * bool * A.attribute list =
  (* Do one element and collect the type specifiers *)
  let isinline = ref false in (* If inline appears *)
  (* The storage is placed here *)
  let storage : storage ref = ref NoStorage in
  (* Collect the attributes *)
  let attrs : A.attribute list ref = ref [] in

  let doSpecElem (acc: A.typeSpecifier list) 
                 (se: A.spec_elem) : A.typeSpecifier list = 
    match se with 
      A.SpecTypedef -> acc
    | A.SpecInline -> isinline := true; acc
    | A.SpecStorage st ->
        if !storage <> NoStorage then 
          E.s (error "Multiple storage specifiers");
        let sto' = 
          match st with
            A.NO_STORAGE -> NoStorage
          | A.AUTO -> NoStorage
          | A.REGISTER -> Register
          | A.STATIC -> Static
          | A.EXTERN -> Extern
        in
        storage := sto';
        acc

    | A.SpecAttr a -> attrs := a :: !attrs; acc
    | A.SpecType ts -> ts :: acc
  in
  (* Now scan the list and collect the type specifiers *)
  let tspecs = List.fold_left doSpecElem [] specs in
  (* Sort the type specifiers *)
  let sortedspecs = 
    let order = function (* Don't change this *)
      | A.Tvoid -> 0
      | A.Tsigned -> 1
      | A.Tunsigned -> 2
      | A.Tchar -> 3
      | A.Tshort -> 4
      | A.Tlong -> 5
      | A.Tint -> 6
      | A.Tint64 -> 7
      | A.Tfloat -> 8
      | A.Tdouble -> 9
      | _ -> 10 (* There should be at most one of the others *)
    in
    List.sort (fun ts1 ts2 -> compare (order ts1) (order ts2)) tspecs 
  in
  (* And now try to make sense of it. See ISO 6.5.2 *)
  let bt = 
    match sortedspecs with
      [A.Tvoid] -> TVoid []
    | [A.Tchar] -> TInt(IChar, [])
    | [A.Tsigned; A.Tchar] -> TInt(ISChar, [])
    | [A.Tunsigned; A.Tchar] -> TInt(IUChar, [])

    | [A.Tshort] -> TInt(IShort, [])
    | [A.Tsigned; A.Tshort] -> TInt(IShort, [])
    | [A.Tshort; A.Tint] -> TInt(IShort, [])
    | [A.Tsigned; A.Tshort; A.Tint] -> TInt(IShort, [])

    | [A.Tunsigned; A.Tshort] -> TInt(IUShort, [])
    | [A.Tunsigned; A.Tshort; A.Tint] -> TInt(IUShort, [])

    | [] -> TInt(IInt, [])
    | [A.Tsigned] -> TInt(IInt, [])
    | [A.Tint] -> TInt(IInt, [])
    | [A.Tsigned; A.Tint] -> TInt(IInt, [])

    | [A.Tunsigned] -> TInt(IUInt, [])
    | [A.Tunsigned; A.Tint] -> TInt(IUInt, [])

    | [A.Tlong] -> TInt(ILong, [])
    | [A.Tsigned; A.Tlong] -> TInt(ILong, [])
    | [A.Tlong; A.Tint] -> TInt(ILong, [])
    | [A.Tsigned; A.Tlong; A.Tint] -> TInt(ILong, [])

    | [A.Tunsigned; A.Tlong] -> TInt(IULong, [])
    | [A.Tunsigned; A.Tlong; A.Tint] -> TInt(IULong, [])

    (* long long seems to have disappeared from the ISO standard *)
    | [A.Tlong; A.Tlong] -> TInt(ILongLong, [])
    | [A.Tlong; A.Tlong; A.Tint] -> TInt(ILongLong, [])
    | [A.Tsigned; A.Tlong; A.Tlong] -> TInt(ILongLong, [])
    | [A.Tsigned; A.Tlong; A.Tlong; A.Tint] -> TInt(ILongLong, [])

    | [A.Tunsigned; A.Tlong; A.Tlong] -> TInt(IULongLong, [])
    | [A.Tunsigned; A.Tlong; A.Tlong; A.Tint] -> TInt(IULongLong, [])

    (* int64 is to support MSVC *)
    | [A.Tint64] -> TInt(ILongLong, [])
    | [A.Tsigned; A.Tint64] -> TInt(ILongLong, [])

    | [A.Tunsigned; A.Tint64] -> TInt(IULongLong, [])

    | [A.Tfloat] -> TFloat(FFloat, [])
    | [A.Tdouble] -> TFloat(FDouble, [])

    | [A.Tlong; A.Tdouble] -> TFloat(FLongDouble, [])

     (* Now the other type specifiers *)
    | [A.Tnamed n] -> begin
        match lookupType "type" n with 
          (TNamed _) as x, _ -> x
        | typ -> E.s (error "Named type %s is not mapped correctly\n" n)
    end

    | [A.Tstruct (n, None)] -> (* A reference to a struct *)
        if n = "" then E.s (error "Missing struct tag on incomplete struct");
        findCompType "struct" n []
    | [A.Tstruct (n, Some nglist)] -> (* A definition of a struct *)
      let n' = if n <> "" then n else anonStructName "struct" in
      makeCompType true n' nglist []
        
    | [A.Tunion (n, None)] -> (* A reference to a union *)
        if n = "" then E.s (error "Missing union tag on incomplete union");
        findCompType "union" n []
    | [A.Tunion (n, Some nglist)] -> (* A definition of a union *)
      let n' = if n <> "" then n else anonStructName "union" in
      makeCompType false n' nglist []
        
    | [A.Tenum (n, None)] -> (* Just a reference to an enum *)
        if n = "" then E.s (error "Missing enum tag on incomplete enum");
        findCompType "enum" n []

    | [A.Tenum (n, Some eil)] -> (* A definition of an enum *)
        let n' = if n <> "" then n else anonStructName "enum" in
        (* make a new name for this enumeration *)
        let n'' = newAlphaName true "enum" n' in
        
        (* sm: start a scope for the enum tag values, since they *
        * can refer to earlier tags *)
        (enterScope ());
        
        (* as each name,value pair is determined, this is called *)
        let rec processName kname i rest = begin
          (* add the name to the environment, but with a faked 'typ' field; we 
          * don't know the full type yet (since that includes all of the tag 
          * values), but we won't need them in here  *)
          (addLocalToEnv kname (EnvEnum (i, TEnum (n'', [], []))));
          
          (* add this tag to the list so that it ends up in the real 
          * environment when we're finished  *)
          let newname = newAlphaName true "" kname in
          (kname, (newname, i)) :: loop (increm i 1) rest
        end
            
        and loop i = function
            [] -> []
          | (kname, A.NOTHING) :: rest ->
              (* use the passed-in 'i' as the value, since none specified *)
              (processName kname i rest)
                
          | (kname, e) :: rest ->
              (* constant-eval 'e' to determine tag value *)
              let i =
                match doExp true e (AExp None) with
                  c, e', _ when isEmpty c -> e'
                | _ -> E.s (error "enum with non-const initializer")
              in
              (processName kname i rest)
        in
        
        (* sm: now throw away the environment we built for eval'ing the enum 
        * tags, so we can add to the new one properly  *)
        (exitScope ());
        
        let fields = loop zero eil in
        let res = TEnum (n'', List.map (fun (_, x) -> x) fields, []) in
        (* Now we have the real host type. Set the environment properly *)
        List.iter
          (fun (n, (newname, fieldidx)) -> 
            addLocalToEnv n (EnvEnum (fieldidx, res)))
          fields;
        (* Record the enum name in the environment *)
        addLocalToEnv (kindPlusName "enum" n'') (EnvTyp res);
        res
          
    | [A.Ttypeof e] -> 
        let (c, _, t) = doExp false e (AExp None) in
        if not (isEmpty c) then
          E.s (error "typeof for a non-pure expression\n");
        t
    | _ -> 
        E.s (error "Bad combination of type specifiers")
  in
  bt,!storage,!isinline,List.rev !attrs

and makeVarInfo 
                (isglob: bool) 
                (ldecl: location)
                ((s,(n,ndt,a)) : A.single_name) : varinfo = 
  let bt, sto, inline, attrs = doSpecList s in
  let vtype, nattr = 
    doType (AttrName false) bt (A.PARENTYPE(attrs, ndt, a)) in
(*  ignore (E.log "makevar:%s@! type=%a@! vattr=%a@!"
            n d_plaintype vtype (d_attrlist true) nattr); *)
  { vname    = n;
    vid      = newVarId n isglob;
    vglob    = isglob;
    vstorage = sto;
    vattr    = nattr;
    vdecl    = ldecl;
    vtype    = vtype;
    vaddrof  = false;
    vreferenced = false;   (* sm *)
  }


and doAttr (a: A.attribute) : attribute list = 
  (* Strip the leading and trailing underscore *)
  let stripUnderscore (n: string) : string = 
    let l = String.length n in
    let rec start i = 
      if i >= l then 
        E.s (error "Invalid attribute name %s" n);
      if String.get n i = '_' then start (i + 1) else i
    in
    let st = start 0 in
    let rec finish i = 
      (* We know that we will stop at >= st >= 0 *)
      if String.get n i = '_' then finish (i - 1) else i
    in
    let fin = finish (l - 1) in
    String.sub n st (fin - st + 1)
  in
  match a with
    (s, []) -> [Attr (stripUnderscore s, [])]
  | (s, el) -> 
      let rec attrOfExp (strip: bool) (a: A.expression) : attrarg =
        match a with
          A.VARIABLE n -> begin
            try 
              let vi, _ = lookupVar n in
              AVar vi
            with Not_found -> 
              AId (if strip then stripUnderscore n else n)
          end
        | A.CONSTANT (A.CONST_STRING s) -> AStr s
        | A.CONSTANT (A.CONST_INT str) -> AInt (int_of_string str)
        | A.CALL(A.VARIABLE n, args) -> 
            ACons ((if strip then stripUnderscore n else n), 
                   List.map (attrOfExp false) args)
        | _ -> E.s (error "Invalid expression in attribute")
      in
      (* Sometimes we need to convert attrarg into attr *)
      let arg2attr = function
          AId s -> Attr (s, [])
        | ACons (s, args) -> Attr (s, args)
        | _ -> E.s (error "Invalid form of attribute")
      in
      if s = "__attribute__" then (* Just a wrapper for many attributes*)
        List.map (fun e -> arg2attr (attrOfExp true e)) el
      else if s = "__declspec" then
        List.map (fun e -> arg2attr (attrOfExp false e)) el
      else
        [Attr(stripUnderscore s, List.map (attrOfExp false) el)]

and doAttributes (al: A.attribute list) : attribute list =
  List.fold_left (fun acc a -> addAttributes (doAttr a) acc) [] al



and doType (nameortype: attributeClass) (* This is AttrName if we are doing 
                                         * the type for a name, or AttrType 
                                         * if we are doing this type in a 
                                         * typedef *)
           (bt: typ)                    (* The base type *)
           (dt: A.decl_type) 
  (* Returns the new type and the accumulated name (or type if nameoftype = 
   * AttrType) attributes *)
  : typ * attribute list = 
  (* Now do the declarator type. But remember that the structure of the 
   * declarator type is as printed, meaning that it is the reverse of the 
   * right one *)
  let rec doDecl (bt: typ) (acc: attribute list) = function
      A.JUSTBASE -> bt, acc
    | A.PARENTYPE (a1, d, a2) -> 
        let a1' = doAttributes a1 in
        let a1n, a1f, a1t = partitionAttributes AttrType a1' in
        let a2' = doAttributes a2 in
        let a2n, a2f, a2t = partitionAttributes nameortype a2' in
        let bt' = typeAddAttributes a1t bt in
        let bt'', a1fadded = 
          match unrollType bt with 
            TFun _ -> typeAddAttributes a1f bt', true
          | _ -> bt', false
        in
        (* Now recurse *)
        let restyp, nattr = doDecl bt'' acc d in
        (* Add some more type attributes *)
        let restyp = typeAddAttributes a2t restyp in
        (* See if we can add some more type attributes *)
        let restyp' = 
          match unrollType restyp with 
            TFun _ -> 
              if a1fadded then
                typeAddAttributes a2f restyp
              else
                typeAddAttributes a2f
                  (typeAddAttributes a1f restyp)
          | TPtr ((TFun _ as tf), ap) when not !msvcMode ->
              if a1fadded then
                TPtr(typeAddAttributes a2f tf, ap)
              else
                TPtr(typeAddAttributes a2f
                       (typeAddAttributes a1f tf), ap)
          | _ -> 
              if a1f <> [] && not a1fadded then
                E.s (error "Invalid position for (prefix) function type attributes:%a" 
                       (d_attrlist true) a1f);
              if a2f <> [] then
                E.s (error "Invalid position for (post) function type attributes:%a"
                       (d_attrlist true) a2f);
              restyp
        in
        (* Now add the name attributes and return *)
        restyp', addAttributes a1n (addAttributes a2n nattr)

    | A.BITFIELD e -> 
        let ikind, a = 
          match unrollType bt with 
            TInt (ikind, a) -> ikind, a
          | _ -> E.s (error "Base type for bitfield is not an integer type")
        in
        let width = match doExp true e (AExp None) with
          (c, Const(CInt(i,_,_)),_) when isEmpty c -> i
        | _ -> E.s (error "bitfield width is not an integer constant")
        in
        TBitfield (ikind, width, a), acc

    | A.PTR (al, d) -> 
        let al' = doAttributes al in
        let an, af, at = partitionAttributes AttrType al' in
        (* Now recurse *)
        let restyp, nattr = doDecl (TPtr(bt, at)) acc d in
        (* See if we can do anything with function type attributes *)
        let restyp' = 
          match unrollType restyp with
            TFun _ -> typeAddAttributes af restyp
          | TPtr((TFun _ as tf), ap) ->
              TPtr(typeAddAttributes af tf, ap)
          | _ -> 
              if af <> [] then
                E.s (error "Invalid position for function type attributes:%a"
                       (d_attrlist true) af);
              restyp
        in
        (* Now add the name attributes and return *)
        restyp', addAttributes an nattr
              

    | A.ARRAY (d, len) -> 
        let lo = 
          match len with 
            A.NOTHING -> None 
          | _ -> 
              let len' = doPureExp len in
              let _, len'' = castTo (typeOf len') intType len' in
              Some len''
        in
        doDecl (TArray(bt, lo, [])) acc d

    | A.PROTO (d, args, isva) -> 
        (* Turn [] types into pointers in the arguments and the result type. 
         * This simplifies our life a lot  *)
        let arrayToPtr t = 
          match unrollType t with
            TArray(t,_,attr) -> TPtr(t, attr)
          | _ -> t
        in
        (* Start a scope for the parameter names *)
        enterScope ();
        let targs = 
          match List.map (makeVarInfo false locUnknown) args  with
            [t] when (match t.vtype with TVoid _ -> true | _ -> false) -> []
          | l -> l
        in
        exitScope ();
        List.iter (fun a -> a.vtype <- arrayToPtr a.vtype) targs;
        let tres = arrayToPtr bt in
        doDecl (TFun (tres, targs, isva, [])) acc d

  in
  doDecl bt [] dt

and doOnlyType (specs: A.spec_elem list) (dt: A.decl_type) : typ = 
  let bt',sto,inl,attrs = doSpecList specs in
  if sto <> NoStorage || inl then
    E.s (error "Storage or inline specifier in type only");
  let tres, nattr = doType AttrType bt' (A.PARENTYPE(attrs, dt, [])) in
  if nattr <> [] then
    E.s (error "Name attributes in only_type: %a"
           (d_attrlist false) nattr);
  tres


and makeCompType (iss: bool)
                 (n: string)
                 (nglist: A.name_group list) 
                 (a: attribute list) = 
  (* Make a new name for the structure *)
  let kind = if iss then "struct" else "union" in
  let n' = newAlphaName true kind n in
  (* Create the self cell for use in fields and forward references. Or maybe 
   * one exists already from a forward reference  *)
  let comp = createCompInfo iss n' in
  (* Do the fields *)
  let makeFieldInfo (s: A.spec_elem list) 
                    ((n,ndt,a) : A.name) : fieldinfo = 
    let bt, sto, inl, attrs = doSpecList s in
    if sto <> NoStorage || inl then 
      E.s (error "Storage or inline not allowed for fields");
    let ftype, nattr = doType (AttrName false) 
                              bt (A.PARENTYPE(attrs, ndt, a)) in 
    { fcomp    =  comp;
      fname    =  n;
      ftype    =  ftype;
      fattr    =  nattr;
    } 
  in
  let flds = List.concat (List.map (doNameGroup makeFieldInfo) nglist) in
  if comp.cfields <> [] then begin
    (* This appears to be a multiply defined structure. This can happen from 
     * a construct like "typedef struct foo { ... } A, B;". This is dangerous 
     * because at the time B is processed some forward references in { ... } 
     * appear as backward references, which coild lead to circularity in 
     * the type structure. We do a thourough check and then we reuse the type 
     * for A *)
    let fieldsSig fs = List.map (fun f -> typeSig f.ftype) fs in 
    if fieldsSig comp.cfields <> fieldsSig flds then
      ignore (warn "%s seems to be multiply defined" (compFullName comp))
  end else 
    comp.cfields <- flds;

      (* Drop volatile from struct
  let a = dropAttribute a (AId("volatile")) in
  let a = dropAttribute a (AId("const")) in
  let a = dropAttribute a (AId("restrict")) in  *)
  comp.cattr <- a;
  let res = TComp (false, comp, []) in
      (* There must be a self cell created for this already *)
  addLocalToEnv (kindPlusName kind n) (EnvTyp res);
  res
  
     (* Process an expression and in the process do some type checking, 
      * extract the effects as separate statements  *)
and doExp (isconst: bool)    (* In a constant *)
          (e : A.expression) 
          (what: expAction) : (chunk * exp * typ) = 
  (* A subexpression of array type is automatically turned into StartOf(e). 
   * Similarly an expression of function type is turned into StartOf *)
  let processStartOf e t = 
    match e, unrollType t with
      Lval(lv), TArray(t, _, a) -> mkAddrOfAndMark lv, TPtr(t, a)
    | Lval(lv), TFun _  -> begin
        match lv with 
          Mem(addr), NoOffset -> addr, TPtr(t, [])
        | _, _ -> mkAddrOfAndMark lv, TPtr(t, [])
    end
(*    | Compound _, TArray(t', _, a) -> e, t *)
    | _, (TArray _ | TFun _) -> 
        E.s (error "Array or function expression is not lval: %a@!"
               d_plainexp e)
    | _ -> e, t
  in
  (* Before we return we call finishExp *)
  let finishExp se e t = 
    match what with 
      ADrop -> (se, e, t)
    | AExp _ -> 
        let (e', t') = processStartOf e t in
        (se, e', t')

    | ASet (lv, lvt) -> begin
        (* See if the set was done already *)
        match e with 
          Lval(lv') when lv == lv' -> (se, e, t)
        | _ -> 
            let (e', t') = processStartOf e t in
            let (t'', e'') = castTo t' lvt e' in
            (se +++ (Set(lv, e'', !currentLoc)), e'', t'')
    end
  in
  let findField n fidlist = 
    try
      List.find (fun fid -> n = fid.fname) fidlist
    with Not_found -> E.s (error "Cannot find field %s" n)
  in
  try
    match e with
    | A.NOTHING when what = ADrop -> finishExp empty (integer 0) intType
    | A.NOTHING ->
        ignore (E.log "doExp nothing\n");
        finishExp empty 
          (Const(CStr("exp_nothing"))) (TPtr(TInt(IChar,[]),[]))

    (* Do the potential lvalues first *)          
    | A.VARIABLE n -> begin
        (* Look up in the environment *)
        try 
          let envdata = H.find env n in
          match envdata with
            EnvVar vi, _ -> 
              finishExp empty (Lval(var vi)) vi.vtype
          | EnvEnum (tag, typ), _ -> 
            finishExp empty tag typ  
          | _ -> raise Not_found
        with Not_found -> 
          ignore (E.log "Cannot resolve variable %s.\n" n);
          raise Not_found
    end
    | A.INDEX (e1, e2) -> begin
        (* Recall that doExp turns arrays into StartOf pointers *)
        let (se1, e1', t1) = doExp false e1 (AExp None) in
        let (se2, e2', t2) = doExp false e2 (AExp None) in
        let se = se1 @@ se2 in
        let (e1'', e2'', tresult) = 
          match unrollType t1, unrollType t2 with
            TPtr(t1e,_), (TInt _|TEnum _ |TBitfield _) -> e1', e2', t1e
          | (TInt _|TEnum _|TBitfield _), TPtr(t2e,_) -> e2', e1', t2e
          | _ -> 
              E.s (error 
                     "Expecting a pointer type in index:@! t1=%a@!t2=%a@!"
                     d_plaintype t1 d_plaintype t2)
        in
        (* Do some optimization of StartOf *)
        finishExp se (mkMem e1'' (Index(e2'', NoOffset))) tresult

    end      
    | A.UNARY (A.MEMOF, e) -> 
        if isconst then
          E.s (error "MEMOF in constant");
        let (se, e', t) = doExp false e (AExp None) in
        let tresult = 
          match unrollType t with
          | TPtr(te, _) -> te
          | _ -> E.s (error "Expecting a pointer type in *. Got %a@!"
                        d_plaintype t)
        in
        finishExp se 
                  (mkMem e' NoOffset)
                  tresult

           (* e.str = (& e + off(str)). If e = (be + beoff) then e.str = (be 
            * + beoff + off(str))  *)
    | A.MEMBEROF (e, str) -> 
        (* member of is actually allowed if we only take the address *)
        (* if isconst then
          E.s (error "MEMBEROF in constant");  *)
        let (se, e', t') = doExp false e (AExp None) in
        let lv = 
          match e' with Lval x -> x 
          | _ -> E.s (error "Expected an lval in MEMDEROF")
        in
        let fid = 
          match unrollType t' with
            TComp (_, comp, _) -> findField str comp.cfields
          | _ -> E.s (error "expecting a struct with field %s" str)
        in
        let lv' = Lval(addOffsetLval (Field(fid, NoOffset)) lv) in
        finishExp se lv' fid.ftype
          
       (* e->str = * (e + off(str)) *)
    | A.MEMBEROFPTR (e, str) -> 
        if isconst then
          E.s (error "MEMBEROFPTR in constant");
        let (se, e', t') = doExp false e (AExp None) in
        let pointedt = 
          match unrollType t' with
            TPtr(t1, _) -> t1
          | TArray(t1,_,_) -> t1
          | _ -> E.s (error "expecting a pointer to a struct")
        in
        let fid = 
          match unrollType pointedt with 
            TComp (_, comp, _) -> findField str comp.cfields
          | x -> 
              E.s (error 
                     "expecting a struct with field %s. Found %a. t1 is %a" 
                     str d_type x d_type t')
        in
        finishExp se (mkMem e' (Field(fid, NoOffset))) fid.ftype
          
          
    | A.CONSTANT ct -> begin
        let finishCt c t = finishExp empty (Const(c)) t in
        let hasSuffix str = 
          let l = String.length str in
          fun s -> 
            let ls = String.length s in
            l >= ls && s = String.uppercase (String.sub str (l - ls) ls)
        in
        match ct with 
          A.CONST_INT str -> begin
            let l = String.length str in
            (* See if it is octal or hex *)
            let octalhex = (l >= 1 && String.get str 0 = '0') in 
            (* The length of the suffix and a list of possible kinds. See ISO 
             * 6.4.4.1 *)
            let hasSuffix = hasSuffix str in
            let suffixlen, kinds = 
              if hasSuffix "ULL" || hasSuffix "LLU" then
                3, [IULongLong]
              else if hasSuffix "LL" then
                2, if octalhex then [ILongLong; IULongLong] else [ILongLong]
              else if hasSuffix "UL" || hasSuffix "LU" then
                2, [IULong; IULongLong]
              else if hasSuffix "L" then
                1, if octalhex then [ILong; IULong; ILongLong; IULongLong] 
                               else [ILong; ILongLong]
              else if hasSuffix "U" then
                1, [IUInt; IULong; IULongLong]
              else
                0, if octalhex 
                   then [IInt; IUInt; ILong; IULong; ILongLong; IULongLong]
                   else [IInt; ILong; ILongLong]
            in
            let baseint = String.sub str 0 (l - suffixlen) in
            try
              let i = int_of_string baseint in
              let res = integerKinds i kinds (Some str) in
              finishCt res (typeOf (Const(res)))
            with e -> begin
              ignore (E.log "int_of_string %s (%s)\n" str 
                        (Printexc.to_string e));
              finishCt (CStr("booo CONS_INT")) (TPtr(TInt(IChar,[]),[]))
            end
          end
        | A.CONST_STRING s -> 
            (* Maybe we burried __FUNCTION__ in there *)
            let s' = 
              try
                let start = String.index s (Char.chr 0) in
                let l = String.length s in
                let tofind = (String.make 1 (Char.chr 0)) ^ "__FUNCTION__" in
                let past = start + String.length tofind in
                if past <= l &&
                   String.sub s start (String.length tofind) = tofind then
                  (if start > 0 then String.sub s 0 start else "") ^
                  !currentFunctionVI.vname ^
                  (if past < l then String.sub s past (l - past) else "")
                else
                  s
              with Not_found -> s
            in
            finishCt (CStr(s')) charPtrType
              
        | A.CONST_CHAR s ->
            let chr = 
              (* Convert the characted into the ASCII code *)
              match explodeString false s with
                [ c ] -> c
              | ['\\'; 'n'] -> '\n'
              | ['\\'; 't'] -> '\t'
              | ['\\'; 'r'] -> '\r'
              | ['\\'; 'b'] -> '\b'
              | ['\\'; '\\'] -> '\\'
              | ['\\'; '\''] -> '\''
              | ['\\'; '\034'] -> '\034'  (* The double quote *)
              | ['\\'; c ] when c >= '0' && c <= '9' -> 
                  Char.chr (Char.code c - Char.code '0')
              | ['\\'; c2; c1 ] when 
                c1 >= '0' && c1 <= '9' && c2 >= '0' && c2 <= '9' -> 
                  Char.chr ((Char.code c1 - Char.code '0') +
                            (Char.code c2 - Char.code '0') * 8)  
              | ['\\'; c3; c2; c1 ] when 
                c1 >= '0' && c1 <= '9' && c2 >= '0' && c2 <= '9'  
                  && c3 >= '0' && c3 <= '9' -> 
                  Char.chr ((Char.code c1 - Char.code '0') +
                            (Char.code c2 - Char.code '0') * 8 + 
                            (Char.code c3 - Char.code '0') * 64)  
              | _ -> E.s (error "Cannot transform \"%s\" into a char\n" s)
            in
            finishCt (CChr(chr)) (TInt(IChar,[]))
              
        | A.CONST_FLOAT str -> begin
            (* Maybe it ends in U or UL. Strip those *)
            let l = String.length str in
            let hasSuffix = hasSuffix str in
            let baseint, kind = 
              if  hasSuffix "L" then
                String.sub str 0 (l - 1), FLongDouble
              else if hasSuffix "F" then
                String.sub str 0 (l - 1), FFloat
              else if hasSuffix "D" then
                String.sub str 0 (l - 1), FDouble
              else
                str, FDouble
            in
            try
              finishCt (CReal(float_of_string baseint, kind,
                              Some str)) (TFloat(kind,[]))
            with e -> begin
              ignore (E.log "float_of_string %s (%s)\n" str 
                        (Printexc.to_string e));
              finishCt (CStr("booo CONS_FLOAT")) (TPtr(TInt(IChar,[]),[]))
            end
        end
    end          
    | A.TYPE_SIZEOF (bt, dt) -> 
        let typ = doOnlyType bt dt in
        finishExp empty (SizeOf(typ)) uintType
          
    | A.EXPR_SIZEOF e -> 
        let (se, e', t) = doExp isconst e (AExp None) in
        (* !!!! The book says that the expression is not evaluated, so we 
           * drop the potential size-effects *)
        if isNotEmpty se then 
          ignore (E.log "Warning: Dropping side-effect in EXPR_SIZEOF\n");
        let e'' = 
          match e' with                 (* If we are taking the sizeof an 
                                         * array we must drop the StartOf  *)
            StartOf(lv) -> Lval(lv)
          | _ -> e'
        in
        finishExp empty (SizeOfE(e'')) uintType

    | A.CAST ((specs, dt), e) -> 
        let typ = doOnlyType specs dt in
        let what' = 
          match e with 
            (* We treat the case when e is COMPOUND differently
            A.CONSTANT (A.CONST_COMPOUND _) -> AExp (Some typ) *)
          | _ -> begin
              match what with
                AExp (Some _) -> AExp (Some typ)
              | ADrop -> ADrop
              | _ -> AExp None
          end
        in
        let (se, e', t) = doExp isconst e what' in
        let (t'', e'') = 
          match typ with
            TVoid _ when what = ADrop -> (t, e') (* strange GNU thing *)
          |  _ -> castTo t typ e'
        in
        finishExp se e'' t''
          
    | A.UNARY(A.MINUS, e) -> 
        let (se, e', t) = doExp isconst e (AExp None) in
        if isIntegralType t then
          let tres = integralPromotion t in
          let e'' = 
            match e' with
            | Const(CInt(i, _, _)) -> integer (- i)
            | _ -> UnOp(Neg, doCastT e' t tres, tres)
          in
          finishExp se e'' tres
        else
          if isArithmeticType t then
            finishExp se (UnOp(Neg,e',t)) t
          else
            E.s (error "Unary - on a non-arithmetic type")
        
    | A.UNARY(A.BNOT, e) -> 
        let (se, e', t) = doExp isconst e (AExp None) in
        if isIntegralType t then
          let tres = integralPromotion t in
          let e'' = UnOp(BNot, doCastT e' t tres, tres) in
          finishExp se e'' tres
        else
          E.s (error "Unary ~ on a non-integral type")
          
    | A.UNARY(A.PLUS, e) -> doExp isconst e what 
          
          
    | A.UNARY(A.ADDROF, e) -> begin
        let (se, e', t) = doExp isconst e (AExp None) in
        match e' with 
          Lval x -> finishExp se (mkAddrOfAndMark x) (TPtr(t, []))
        | CastE (t', Lval x) -> 
            finishExp se (CastE(TPtr(t', []),
                                (mkAddrOfAndMark x))) (TPtr(t', []))
        | StartOf (lv) -> (* !!! is this correct ? *)
            let tres = TPtr(typeOfLval lv, []) in
            finishExp se (mkAddrOfAndMark lv) tres

            
        | _ -> E.s (error "Expected lval for ADDROF. Got %a@!"
                      d_plainexp e')
    end
    | A.UNARY((A.PREINCR|A.PREDECR) as uop, e) -> 
        let uop' = if uop = A.PREINCR then PlusA else MinusA in
        if isconst then
          E.s (error "PREINCR or PREDECR in constant");
        let (se, e', t) = doExp false e (AExp None) in
        let lv = 
          match e' with 
            Lval x -> x
          | CastE (_, Lval x) -> x
          | _ -> E.s (error "Expected lval for ++ or --")
        in
        let tresult, result = doBinOp uop' (Lval(lv)) t one intType in
        finishExp (se +++ (Set(lv, doCastT result tresult t, !currentLoc)))
          (Lval(lv))
          tresult   (* Should this be t instead ??? *)
          
    | A.UNARY((A.POSINCR|A.POSDECR) as uop, e) -> 
        if isconst then
          E.s (error "POSTINCR or POSTDECR in constant");
        (* If we do not drop the result then we must save the value *)
        let uop' = if uop = A.POSINCR then PlusA else MinusA in
        let (se, e', t) = doExp false e (AExp None) in
        let lv = 
          match e' with 
            Lval x -> x
          | CastE (_, Lval x) -> x
          | _ -> E.s (error "Expected lval for ++ or --")
        in
        let tresult, opresult = doBinOp uop' (Lval(lv)) t one intType in
        let se', result = 
          if what <> ADrop then 
            let tmp = newTempVar t in
            se +++ (Set(var tmp, Lval(lv), !currentLoc)), Lval(var tmp)
          else
            se, Lval(lv)
        in
        finishExp (se' +++ (Set(lv, doCastT opresult tresult t, !currentLoc)))
          result
          tresult   (* Should this be t instead ??? *)
          
    | A.BINARY(A.ASSIGN, e1, e2) -> 
        if isconst then
          E.s (error "ASSIGN in constant");
        let (se1, e1', lvt) = doExp false e1 (AExp None) in
        let lv, lvt' = 
          match e1' with 
            Lval x -> x, lvt
          | CastE (_, Lval x) -> x, typeOfLval x
          | _ -> E.s (error "Expected lval for assignment. Got %a\n"
                        d_plainexp e1')
        in
        let (se2, e'', t'') = doExp false e2 (ASet(lv, lvt')) in
        finishExp (se1 @@ se2) (Lval(lv)) lvt'
          
    | A.BINARY((A.ADD|A.SUB|A.MUL|A.DIV|A.MOD|A.BAND|A.BOR|A.XOR|
      A.SHL|A.SHR|A.EQ|A.NE|A.LT|A.GT|A.GE|A.LE) as bop, e1, e2) -> 
        let bop' = match bop with
          A.ADD -> PlusA
        | A.SUB -> MinusA
        | A.MUL -> Mult
        | A.DIV -> Div
        | A.MOD -> Mod
        | A.BAND -> BAnd
        | A.BOR -> BOr
        | A.XOR -> BXor
        | A.SHL -> Shiftlt
        | A.SHR -> Shiftrt
        | A.EQ -> Eq
        | A.NE -> Ne
        | A.LT -> Lt
        | A.LE -> Le
        | A.GT -> Gt
        | A.GE -> Ge
        | _ -> E.s (error "binary +")
        in
        let (se1, e1', t1) = doExp isconst e1 (AExp None) in
        let (se2, e2', t2) = doExp isconst e2 (AExp None) in
        let tresult, result = doBinOp bop' e1' t1 e2' t2 in
        finishExp (se1 @@ se2) result tresult
          
    | A.BINARY((A.ADD_ASSIGN|A.SUB_ASSIGN|A.MUL_ASSIGN|A.DIV_ASSIGN|
      A.MOD_ASSIGN|A.BAND_ASSIGN|A.BOR_ASSIGN|A.SHL_ASSIGN|
      A.SHR_ASSIGN|A.XOR_ASSIGN) as bop, e1, e2) -> 
        if isconst then
          E.s (error "op_ASSIGN in constant");
        let bop' = match bop with          
          A.ADD_ASSIGN -> PlusA
        | A.SUB_ASSIGN -> MinusA
        | A.MUL_ASSIGN -> Mult
        | A.DIV_ASSIGN -> Div
        | A.MOD_ASSIGN -> Mod
        | A.BAND_ASSIGN -> BAnd
        | A.BOR_ASSIGN -> BOr
        | A.XOR_ASSIGN -> BXor
        | A.SHL_ASSIGN -> Shiftlt
        | A.SHR_ASSIGN -> Shiftrt
        | _ -> E.s (error "binary +=")
        in
        let (se1, e1', t1) = doExp false e1 (AExp None) in
        let lv1 = 
          match e1' with Lval x -> x
          | _ -> E.s (error "Expected lval for assignment")
        in
        let (se2, e2', t2) = doExp false e2 (AExp None) in
        let tresult, result = doBinOp bop' e1' t1 e2' t2 in
        finishExp (se1 @@ se2 +++ (Set(lv1, result, !currentLoc)))
          (Lval(lv1))
          tresult
          
    | A.BINARY((A.AND|A.OR), e1, e2) ->
        let tmp = var (newTempVar intType) in
        finishExp (doCondition e (empty +++ (Set(tmp, integer 1, !currentLoc)))
                                 (empty +++ (Set(tmp, integer 0, !currentLoc))))     
          (Lval tmp)
          intType
          
    | A.UNARY(A.NOT, e) -> 
        let tmp = var (newTempVar intType) in
        let (se, e', t) as rese = doExp isconst e (AExp None) in
        ignore (checkBool t e');
        finishExp se (UnOp(LNot, e', intType)) intType
(*   We could use this code but it confuses the translation validation
        finishExp 
          (doCondition e [mkSet tmp (integer 0)] [mkSet tmp (integer 1)])
          (Lval tmp)
          intType
*)
          
    | A.CALL(f, args) -> 
        if isconst then
          E.s (error "CALL in constant");
        let (sf, f', ft') = 
          match f with                  (* Treat the VARIABLE case separate 
                                         * becase we might be calling a 
                                         * function that does not have a 
                                         * prototype. In that case assume it 
                                         * takes INTs as arguments  *)
            A.VARIABLE n -> begin
              try
                let vi, _ = lookupVar n in
                (empty, Lval(var vi), vi.vtype) (* Found. Do not use 
                                                 * finishExp. Simulate what = 
                                                 * AExp None  *)
              with Not_found -> begin
                ignore (warn "Calling function %s without prototype\n" n);
                let ftype = TFun(intType, [], false, []) in
                (* Add a prototype to the environment *)
                let proto, _ = makeGlobalVarinfo (makeGlobalVar n ftype) in
                (* Make it EXTERN *)
                proto.vstorage <- Extern;
                (* Add it to the file as well *)
                theFile := GDecl (proto, !currentLoc) :: !theFile;
                (empty, Lval(var proto), ftype)
              end
            end
          | _ -> doExp false f (AExp None) 
        in
        (* Get the result type and the argument types *)
        let (resType, argTypes, isvar, f'') = 
          match unrollType ft' with
            TFun(rt,at,isvar,a) -> (rt,at,isvar,f')
          | TPtr (t, _) -> begin
              match unrollType t with 
                TFun(rt,at,isvar,a) -> (* Make the function pointer 
                                            * explicit  *)
                  let f'' = 
                    match f' with
                      StartOf lv -> Lval(lv)
                    | _ -> Lval(Mem(f'), NoOffset)
                  in
                  (rt,at,isvar, f'')
              | x -> E.s (error 
                            "Unexpected type of the called function %a: %a" 
                            d_exp f' d_type x)
          end
          | x ->  E.s (error 
                         "Unexpected type of the called function %a: %a" 
                         d_exp f' d_type x)
        in
        (* Drop certain qualifiers from the result type *)
        let resType' =  
          typeRemoveAttributes [Attr("cdecl", [])] resType in
        (* Do the arguments. In REVERSE order !!! Both GCC and MSVC do this *)
        let rec loopArgs 
            : varinfo list * A.expression list 
          -> (chunk * exp list) = function
            | (args, []) -> 
                if args <> [] then
                  ignore (warn "Too few arguments in call to %a" d_exp f');
                (empty, [])

            | (varg :: atypes, a :: args) -> 
                let (ss, args') = loopArgs (atypes, args) in
                let (sa, a', att) = doExp false a (AExp (Some varg.vtype)) in
                let (at'', a'') = castTo att varg.vtype a' in
                (ss @@ sa, a'' :: args')
                  
            | ([], args) -> (* No more types *)
                if not isvar then 
                  ignore (warn "Too many arguments in call to %a" d_exp f');
                let rec loop = function
                    [] -> (empty, [])
                  | a :: args -> 
                      let (ss, args') = loop args in
                      let (sa, a', at) = doExp false a (AExp None) in
                      (ss @@ sa, a' :: args')
                in
                loop args
        in
        let (sargs, args') = loopArgs (argTypes, args) in
        begin
          match what with 
            ADrop -> 
              finishExp 
                (sf @@ sargs +++ (Call(None,f'',args', !currentLoc)))
                (integer 0) intType
              (* Set to a variable of corresponding type *)
          | ASet((Var vi, NoOffset) as lv, vtype) -> 
              let mustCast = typeSig resType' <> typeSig vtype in
              finishExp 
                (sf @@ sargs                                         
                 +++ (Call(Some (vi, mustCast),f'',args', !currentLoc)))
                (Lval(lv))
                vtype

          | _ -> begin
              (* Must create a temporary *)
              match f'', args' with     (* Some constant folding *)
                Lval(Var fv, NoOffset), [Const _] 
                  when fv.vname = "__builtin_constant_p" ->
                    finishExp (sf @@ sargs) (integer 1) intType
              | _ -> 
                  let tmp, restyp', iscast = 
                    match what with
                      AExp (Some t) -> 
                        newTempVar t, t, 
                        typeSig t <> typeSig resType'
                    | _ -> newTempVar resType', resType', false
                  in
                  let i = Call(Some (tmp, iscast),f'',args', !currentLoc) in
                  finishExp (sf @@ sargs +++ i) (Lval(var tmp)) restyp'
          end
        end
          
    | A.COMMA el -> 
        if isconst then 
          E.s (error "COMMA in constant");
        let rec loop sofar = function
            [e] -> 
              let (se, e', t') = doExp false e what in (* Pass on the action *)
              finishExp (sofar @@ se) e' t' (* does not hurt to do it twice *)
          | e :: rest -> 
              let (se, _, _) = doExp false e ADrop in
              loop (sofar @@ se) rest
          | [] -> E.s (error "empty COMMA expression")
        in
        loop empty el
          
    | A.QUESTION (e1,e2,e3) when what = ADrop -> 
        if isconst then
          E.s (error "QUESTION with ADrop in constant");
        let (se3,_,_) = doExp false e3 ADrop in
        let se2 = 
          match e2 with 
            A.NOTHING -> skipChunk
          | _ -> let (se2,_,_) = doExp false e2 ADrop in se2
        in
        finishExp (doCondition e1 se2 se3) (integer 0) intType
          
    | A.QUESTION (e1, e2, e3) -> begin (* what is not ADrop *)
                    (* Do these only to collect the types  *)
        let se2, e2', t2' = 
          match e2 with 
            A.NOTHING -> (* A GNU thing. Use e1 as e2 *) 
              doExp isconst e1 (AExp None)
          | _ -> doExp isconst e2 (AExp None) in 
        let se3, e3', t3' = doExp isconst e3 (AExp None) in
        let tresult = conditionalConversion e2' t2' e3' t3' in
        match e2 with 
          A.NOTHING -> 
              let tmp = var (newTempVar tresult) in
              let (se1, _, _) = doExp isconst e1 (ASet(tmp, tresult)) in
              let (se3, _, _) = doExp isconst e3 (ASet(tmp, tresult)) in
              finishExp (se1 @@ ifChunk (Lval(tmp)) lu
                                  skipChunk se3)
                (Lval(tmp))
                tresult
        | _ -> 
            if isEmpty se2 && isEmpty se3 && isconst then begin 
                                       (* Use the Question *)
              let se1, e1', t1 = doExp isconst e1 (AExp None) in
              ignore (checkBool t1 e1');
              let e2'' = doCastT e2' t2' tresult in
              let e3'' = doCastT e3' t3' tresult in
              let resexp = 
                match e1' with
                  Const(CInt(i, _, _)) when i <> 0 -> e2''
                | Const(CInt(0, _, _)) -> e3''
                | _ -> Question(e1', e2'', e3'')
              in
              finishExp se1 resexp tresult
            end else (* Use a conditional *)
              let lv, lvt = 
                match what with
                | ASet (lv, lvt) -> lv, lvt
                | _ -> 
                    let tmp = newTempVar tresult in
                    var tmp, tresult
              in
              (* Now do e2 and e3 for real *)
              let (se2, _, _) = doExp isconst e2 (ASet(lv, lvt)) in
              let (se3, _, _) = doExp isconst e3 (ASet(lv, lvt)) in
              finishExp (doCondition e1 se2 se3) (Lval(lv)) tresult
    end

    | A.GNU_BODY b -> begin
        (* Find the last A.COMPUTATION *)
        let rec findLastComputation = function
            A.BSTM s :: _  -> 
              let rec findLast = function
                  A.SEQUENCE (_, s, loc) -> findLast s
                | (A.COMPUTATION _) as s -> s
                | _ -> raise Not_found
              in
              findLast s
          | _ :: rest -> findLastComputation rest
          | [] -> raise Not_found
        in
        (* Save the previous data *)
        let old_gnu = ! gnu_body_result in
        let lastComp, isvoidbody = 
          try findLastComputation (List.rev b), false    
          with Not_found -> A.NOP cabslu, true
        in
        (* Prepare some data to be filled by doExp *)
        let data : (exp * typ) option ref = ref None in
        gnu_body_result := (lastComp, data);
        let se = doBody b in
        gnu_body_result := old_gnu;
        match !data with
          None when isvoidbody -> finishExp se zero voidType
        | None -> E.s (error "Cannot find COMPUTATION in GNU.body")
        | Some (e, t) -> finishExp se e t
    end
  with e -> begin
    ignore (E.log "error in doExp (%s)@!" (Printexc.to_string e));
    (i2c (dInstr (dprintf "booo_exp(%t)" d_thisloc) !currentLoc),
     integer 0, intType)
  end
    
(* bop is always the arithmetic version. Change it to the appropriate pointer 
 * version if necessary *)
and doBinOp (bop: binop) (e1: exp) (t1: typ) (e2: exp) (t2: typ) : typ * exp =
  let doArithmetic () = 
    let tres = arithmeticConversion t1 t2 in
    (* Keep the operator since it is arithmetic *)
    tres, constFoldBinOp bop (doCastT e1 t1 tres) (doCastT e2 t2 tres) tres
  in
  let doArithmeticComp () = 
    let tres = arithmeticConversion t1 t2 in
    (* Keep the operator since it is arithemtic *)
    intType, 
    constFoldBinOp bop (doCastT e1 t1 tres) (doCastT e2 t2 tres) intType
  in
  let doIntegralArithmetic () = 
    let tres = unrollType (arithmeticConversion t1 t2) in
    match tres with
      TInt _ -> 
        tres,
        constFoldBinOp bop (doCastT e1 t1 tres) (doCastT e2 t2 tres) tres
    | _ -> E.s (error "%a operator on a non-integer type" d_binop bop)
  in
  let bop2point = function
      MinusA -> MinusPP
    | Eq -> EqP | Ge -> GeP | Ne -> NeP | Gt -> GtP | Le -> LeP | Lt -> LtP
    | _ -> E.s (error "bop2point")
  in
  let pointerComparison e1 e2 = 
    (* Cast both sides to the same kind of pointer, that is preferably not 
     * void* *)
    let commontype = 
      match unrollType t1, unrollType t2 with
        TPtr(TVoid _, _), _ -> t2
      | _, TPtr(TVoid _, _) -> t1
      | _, _ -> t1
    in
    intType,
    constFoldBinOp (bop2point bop) (doCastT e1 t1 commontype) 
      (doCastT e2 t2 commontype) intType
  in

  match bop with
    (Mult|Div) -> doArithmetic ()
  | (Mod|BAnd|BOr|BXor) -> doIntegralArithmetic ()
  | (Shiftlt|Shiftrt) -> (* ISO 6.5.7. Only integral promotions. The result 
                          * has the same type as the left hand side *)
      if !msvcMode then
        (* MSVC has a bug. We duplicate it here *)
        doIntegralArithmetic ()
      else
        let t1' = integralPromotion t1 in
        let t2' = integralPromotion t2 in
        t1', 
        constFoldBinOp bop (doCastT e1 t1 t1') (doCastT e2 t2 t2') t1'

  | (PlusA|MinusA) 
      when isArithmeticType t1 && isArithmeticType t2 -> doArithmetic ()
  | (Eq|Ne|Lt|Le|Ge|Gt) 
      when isArithmeticType t1 && isArithmeticType t2 -> 
        doArithmeticComp ()
  | PlusA when isPointerType t1 && isIntegralType t2 -> 
      t1, constFoldBinOp PlusPI e1 (doCastT e2 t2 (integralPromotion t2)) t1
  | PlusA when isIntegralType t1 && isPointerType t2 -> 
      t2, constFoldBinOp PlusPI e2 (doCastT e1 t1 (integralPromotion t1)) t2
  | MinusA when isPointerType t1 && isIntegralType t2 -> 
      t1, constFoldBinOp MinusPI e1 (doCastT e2 t2 (integralPromotion t2)) t1
  | (MinusA|Le|Lt|Ge|Gt|Eq|Ne) when isPointerType t1 && isPointerType t2 ->
      pointerComparison e1 e2
  | (Eq|Ne) when isPointerType t1 && 
                 (match e2 with Const(CInt(0,_,_)) -> true | _ -> false) -> 
      pointerComparison e1 (doCastT e2 t2 t1)
  | (Eq|Ne) when isPointerType t2 && 
                 (match e1 with Const(CInt(0,_,_)) -> true | _ -> false) -> 
      pointerComparison (doCastT e1 t1 t2) e2


  | (Eq|Ne|Le|Lt|Ge|Gt|Eq|Ne) when isPointerType t1 && isArithmeticType t2 ->
      ignore (warn "Comparison of pointer and non-pointer");
      doBinOp bop (doCastT e1 t1 t2) t2 e2 t2
  | (Eq|Ne|Le|Lt|Ge|Gt|Eq|Ne) when isArithmeticType t1 && isPointerType t2 ->
      ignore (warn "Comparison of pointer and non-pointer");
      doBinOp bop e1 t1 (doCastT e2 t2 t1) t1

  | _ -> E.s (error "doBinOp: %a\n" d_plainexp (BinOp(bop,e1,e2,intType)))

(* A special case for conditionals *)
and doCondition (e: A.expression) 
                (st: chunk)
                (sf: chunk) : chunk = 
  match e with 
  | A.BINARY(A.AND, e1, e2) ->
      let (sf1, sf2) = 
        (* If sf is small then will copy it *)
        if canDuplicate sf then
          (sf, sf)
        else begin
          incr labelId;
          let lab = "L" ^ (string_of_int !labelId) in
          (gotoChunk lab lu, consLabel lab sf)
        end
      in
      let st' = doCondition e2 st sf1 in
      let sf' = sf2 in
      doCondition e1 st' sf'

  | A.BINARY(A.OR, e1, e2) ->
      let (st1, st2) = 
        (* If st is small then will copy it *)
        if canDuplicate st then
          (st, st)
        else begin

          incr labelId;
          let lab = "L" ^ (string_of_int !labelId) in
          (gotoChunk lab lu, consLabel lab st)
        end
      in
      let st' = st1 in
      let sf' = doCondition e2 st2 sf in
      doCondition e1 st' sf'

  | A.UNARY(A.NOT, e) -> doCondition e sf st

  | _ -> begin
      let (se, e, t) as rese = doExp false e (AExp None) in
      ignore (checkBool t e);
      match e with 
        Const(CInt(i,_,_)) when i <> 0 && canDrop sf -> se @@ st
      | Const(CInt(0,_,_)) when canDrop st -> se @@ sf
      | _ -> se @@ ifChunk e !currentLoc st sf
  end

and doPureExp (e : A.expression) : exp = 
  let (se, e', _) = doExp true e (AExp None) in
  if isNotEmpty se then
   E.s (error "doPureExp: not pure");
  e'

(* Process an initializer. *)
and doInitializer 
  (isconst: bool)
  (typ: typ) (* expected type *)
  (acc: chunk) (* Accumulate here the chunk so far *)
  (initl: (A.initwhat * A.init_expression) list) (* Some initializers, might 
                                              * consume one or more  *)

    (* Return some statements, the initializer expression with the new type 
     * (might be different for arrays), and the residual initializers *)
  : chunk * init * typ * (A.initwhat * A.init_expression) list = 

  (* Look at the type to be initialized *)
   (* ARRAYS *)
  match unrollType typ with 
  | TArray(elt,n,a) as oldt -> 
      (* Grab the length if there is one *)
      let leno = 
        match n with
          None -> None
        | Some n' -> begin
            match constFold n' with
            | Const(CInt(ni, _, _)) -> Some ni
            | _ -> E.s (error "Cannot understand the length of the array being initialized\n")
        end
      in
      let rec initArray 
         (nextidx: int) (* The index of the element to be initialized next *)
         (sofar: init list) (* Array elements already initialized, in reverse 
                            * order  *)
         (acc: chunk) 
         (initl: (A.initwhat * A.init_expression) list)
                     (* Return the array elements, the nextidx and the 
                      * remaining initializers *)
         : chunk * init list * int * (A.initwhat * A.init_expression) list = 
        let isValidIndex (i: int) = 
          match leno with Some len -> i < len | _ -> true
        in
        match initl with
           (* Check if we are done *)
        | _ when initl = [] || not (isValidIndex nextidx) ->
            acc, List.rev sofar, nextidx, initl
              
           (* Check if we have a field designator *)         
        | (A.ATINDEX_INIT (idxe, A.NEXT_INIT), ie) :: restinitl ->
            let nextidx', doidx = 
              let (doidx, idxe', _) = 
                doExp isconst idxe (AExp(Some intType)) in
              match constFold idxe' with
                Const(CInt(x, _, _)) -> x, doidx
              | _ -> E.s (error 
                       "INDEX initialization designator is not a constant")
            in
            if nextidx' < nextidx || not (isValidIndex nextidx') then begin
              E.s (error "INDEX init designator is too large (%d >= %d)\n"
                     nextidx' nextidx);
            end;
            (* Initialize with zero the skipped elements *)
            let rec loop i acc = 
              if i = nextidx' then acc
              else loop (i + 1) (makeZeroInit elt :: acc)
            in
            (* now recurse *)
            initArray nextidx' (loop nextidx sofar) 
              (acc @@ doidx) 
              ((A.NEXT_INIT, ie) :: restinitl)
              
        (* Now do the regular case *)
        | (A.NEXT_INIT, ie) :: restinitl -> begin
                  (* If the element type is Char and the initializer is a 
                   * string literal, split the string into characters, 
                   * including the terminal 0 *)
            let isStringLiteral : string option = 
              match ie with
                A.SINGLE_INIT(A.CONSTANT (A.CONST_STRING s)) -> Some s
                 (* The string literal may be enclosed in braces *)
              | A.COMPOUND_INIT [(A.NEXT_INIT, 
                                  A.SINGLE_INIT(A.CONSTANT 
                                                  (A.CONST_STRING s)))]
                -> Some s
              | _ -> None
            in
            match unrollType elt, isStringLiteral with 
              TInt((IChar|ISChar|IUChar), _), Some s -> 
                let chars = explodeString true s in
                let inits' = 
                  List.map 
                    (fun c -> 
                      let cs = String.make 1 c in
                      let cs = Cprint.escape_string cs in 
                      (A.NEXT_INIT, 
                       A.SINGLE_INIT(A.CONSTANT 
                                       (A.CONST_CHAR cs)))) chars in
                initArray nextidx sofar acc (inits' @ restinitl)
            | _ ->   
                (* Recurse and consume some initializers for the purpose of 
                 * initializing one element *)
(*                ignore (E.log "Do the array init for %d\n" nextidx); *)
                let acc', ie', _, initl' = doInitializer false elt acc initl in
                (* And continue with the array *)
                initArray (nextidx + 1) 
                  (ie' :: sofar) 
                  acc'
                  initl'
        end
        | _ -> E.s (error "Invalid designator in initialization of array")
      in
      (* Maybe the first initializer is a compound, then that is the 
       * initializer for the entire array *)
      let acc', inits, nextidx, restinitl = 
        match initl with
          (A.NEXT_INIT, A.COMPOUND_INIT initl_e) :: restinitl -> 
            let acc', inits, nextidx, rest' = 
              initArray 0 [] acc initl_e in
            if rest' <> [] then
              E.s (warn "Unused initializers\n");
            acc', inits, nextidx, restinitl
        | _ -> initArray 0 [] acc initl 
      in
      let newt = (* Maybe we have a length now *)
        match n with 
          None -> TArray(elt, Some(integer nextidx), a)
        | Some _ -> oldt 
      in
      acc', CompoundInit(newt, inits), newt, restinitl
  (* STRUCT or UNION *)
  | TComp (_, comp, a) ->  begin
      let rec initStructUnion
         (nextflds: fieldinfo list) (* Remaining fields *)
         (sofar: init list) (* The initializer expressions so far, in reverse 
                             * order *)
         (acc: chunk)
         (initl: (A.initwhat * A.init_expression) list) 
       
          (* Return the list of initializer expressions and the remaining 
           * initializers  *)
         : chunk * init list * (A.initwhat * A.init_expression) list = 
        match initl with
          (* Check if we are done *)
        | _ when 
          (initl = [] || nextflds = [] ||
                 (* For unions only the first field is initialized *)
            (not comp.cstruct && List.length sofar = 1)) -> 
              acc, List.rev sofar, initl

          (* Check if we have a field designator *)
        | (A.INFIELD_INIT (fn, A.NEXT_INIT), ie) :: restinitl 
                                                      when comp.cstruct ->
            let nextflds', sofar' = 
              let rec findField (sofar: init list) = function
                  [] -> E.s 
                      (error "Cannot find designated field %s"  fn)
                | f :: restf when f.fname = fn -> 
                    f :: restf, sofar
                      
                | f :: restf -> 
                    findField (makeZeroInit f.ftype :: sofar) restf
              in
              findField sofar nextflds 
            in
            (* Now recurse *)
            initStructUnion nextflds' sofar' 
              acc
              ((A.NEXT_INIT, ie) :: restinitl)

           (* Now the regular case *)
         
        | (A.NEXT_INIT, _) :: _  ->
            let nextflds', thisexpt = 
              match nextflds with
                [] -> E.s (error "Too many initializers")
              | x :: xs -> 
(*                  ignore (E.log "Do the comp init for %s\n" x.fname); *)
                  xs, x.ftype
            in
             (* Now do the expression. Give it a chance to consume some 
              * initializers  *)
            let acc', ie', _, initl' = 
              doInitializer isconst thisexpt acc initl in
             (* And continue with the remaining fields *)
            initStructUnion nextflds' (ie' :: sofar) acc' initl'

           (* And the error case *)
        | (A.ATINDEX_INIT _, _) :: _ -> 
            E.s (error "INDEX designator in struct\n");
        | _ -> E.s (error "Invalid designator for struct")
      in
      (* Maybe the first initializer is a compound, then that is the 
       * initializer for the entire array *)
        match initl with
          (A.NEXT_INIT, A.COMPOUND_INIT initl_e) :: restinitl -> 
            let acc', inits, rest' = 
              initStructUnion comp.cfields [] acc initl_e in
            if rest' <> [] then
              E.s (warn "Unused initializers\n");
            acc', CompoundInit(typ, inits), typ, restinitl

           (* Maybe it is a single initializer *)
        | (A.NEXT_INIT, A.SINGLE_INIT oneinit) :: [] -> 
            let se, init', t' = doExp isconst oneinit (AExp(Some typ)) in
            (se @@ acc), SingleInit (doCastT init' t' typ), typ, []
            
        | _ -> 
            let acc', inits, restinitl = 
              initStructUnion comp.cfields [] acc initl 
            in
            acc', CompoundInit(typ, inits), typ, restinitl
  end
   (* REGULAR TYPE *)
  | typ' -> begin
      let oneinit, restinitl = 
        match initl with 
          (A.NEXT_INIT, A.SINGLE_INIT oneinit) :: restinitl -> 
            oneinit, restinitl

        (* We can have an optional brace *)
        | (A.NEXT_INIT, 
           A.COMPOUND_INIT [A.NEXT_INIT, 
                             A.SINGLE_INIT oneinit]) :: restinitl -> 
            oneinit, restinitl
        | _ -> E.s (error "Cannot find the initializer\n")
      in
      let se, init', t' = doExp isconst oneinit (AExp(Some typ')) in
      (se @@ acc), SingleInit (doCastT init' t' typ'), typ', restinitl
  end





and createGlobal (specs: A.spec_elem list) 
                 (((n,ndt,a),e) : A.init_name) : unit = 
  try
            (* Make a first version of the varinfo *)
    let vi = makeVarInfo true locUnknown (specs, (n, ndt, a)) in
            (* Do the initializer and complete the array type if necessary *)
    let init : init option = 
      if e = A.NO_INIT then 
        None
      else 
        let se, ie', et, restinitl = 
          doInitializer true vi.vtype empty [ (A.NEXT_INIT, e) ] in
        if restinitl <> [] then
          E.s (error "Unused initializer in createGlobal\n");
        (* Maybe we now have a better type *)
        vi.vtype <- et;
        if isNotEmpty se then 
          E.s (error "global initializer");
        Some ie'
    in

    (* sm: if it's a function prototype, and the storage class *)
    (* isn't specified, make it 'extern'; this fixes a problem *)
    (* with no-storage prototype and static definition *)
    if (isFunctionType vi.vtype &&
        vi.vstorage = NoStorage) then (
      (*(trace "sm" (dprintf "adding extern to prototype of %s\n" n));*)
      vi.vstorage <- Extern
    );

    let vi, alreadyDef = makeGlobalVarinfo vi in
    if not alreadyDef then begin(* Do not add declarations after def *)
      if vi.vstorage = Extern then 
        if init = None then 
          theFile := GDecl (vi, !currentLoc) :: !theFile
        else
          E.s (error "%s is extern and with initializer" vi.vname)
      else
                (* If it has fucntion type it is a declaration *)
        if isFunctionType vi.vtype then begin
          if init <> None then
            E.s (error "Function declaration with initializer (%s)\n"
                   vi.vname);
          theFile := GDecl(vi, !currentLoc) :: !theFile
        end else
          theFile := GVar(vi, init, !currentLoc) :: !theFile
    end
  with e -> begin
    ignore (E.log "error in CollectGlobal (%s)\n" n);
    theFile := dGlobal (dprintf "booo - error in global %s (%t)" 
                          n d_thisloc) !currentLoc :: !theFile
  end
(*
          ignore (E.log "Env after processing global %s is:@!%t@!" 
                    n docEnv);
          ignore (E.log "Alpha after processing global %s is:@!%t@!" 
                    n docAlphaTable)
*)

(* Must catch the Static local variables.Make them global *)
and createLocal (specs: A.spec_elem list) 
                (((n, ndt, a) as name, (e: A.init_expression)) as init_name) 
  : chunk =
  match ndt with 
    _ when A.isStatic specs -> 
      (* Now alpha convert it to make sure that it does not conflict with 
       * existing globals or locals from this function. *)
      let newname = newAlphaName true "" n in
      (* Make it global  *)
      let vi = makeVarInfo true locUnknown (specs, (newname, ndt, a)) in
      (* Add it to the environment as a local so that the name goes out of 
       * scope properly *)
      addLocalToEnv n (EnvVar vi);
      let init : init option = 
        if e = A.NO_INIT then 
          None
        else begin 
          let se, ie', et, restinitl = 
            doInitializer true vi.vtype empty [ (A.NEXT_INIT, e) ] in
          if restinitl <> [] then
            E.s (error "Unused initializer in createGlobal\n");
          (* Maybe we now have a better type *)
          vi.vtype <- et;
          if isNotEmpty se then 
            E.s (error "global static initializer");
          Some ie'
        end
      in
      theFile := GVar(vi, init, !currentLoc) :: !theFile;
      empty

  (* Maybe we have an extern declaration. Make it a global *)
  | _ when A.isExtern specs ->
      createGlobal specs init_name;
      empty

  (* Maybe we have a function prototype in local scope. Make it global *)
  | A.PROTO _ -> 
      createGlobal specs init_name;
      empty
    
  | _ -> 
      let vi = makeVarInfo false locUnknown (specs, (n, ndt, a)) in
      let vi = alphaConvertVarAndAddToEnv true vi in        (* Replace vi *)
      if e = A.NO_INIT then
        skipChunk
      else begin
        let se, ie', et, _ = 
          doInitializer false vi.vtype empty [ (A.NEXT_INIT, e) ] in
        (match vi.vtype, ie', et with 
            (* We have a length now *)
          TArray(_,None, _), _, TArray(_, Some _, _) -> vi.vtype <- et
            (* Initializing a local array *)
        | TArray(TInt((IChar|IUChar|ISChar), _) as bt, None, a),
             SingleInit(Const(CStr s)), _ -> 
               vi.vtype <- TArray(bt, 
                                  Some (integer (String.length s + 1)),
                                  a)
        | _, _, _ -> ());
        (* Now create assignments instead of the initialization *)
        se @@ (assignInit (Var vi, NoOffset) ie' et empty)
      end
          
          
and doDecl : A.definition -> chunk = function
  | A.DECDEF ((s, nl), loc) ->
      currentLoc := convLoc(loc);
      let stmts = doNameGroup createLocal (s, nl) in
      List.fold_left (fun acc c -> acc @@ c) empty stmts

  | A.TYPEDEF (ng, loc) -> 
     currentLoc := convLoc(loc);
     doTypedef ng; empty

  | A.ONLYTYPEDEF (s, loc) -> 
      currentLoc := convLoc(loc);
      doOnlyTypedef s; empty

  | _ -> E.s (error "local declaration")

and doTypedef ((specs, nl): A.name_group) = 
  try
    let bt, sto, inl, attrs = doSpecList specs in
    if sto <> NoStorage || inl then 
      E.s (error "Storage or inline specifier not allowed in typedef");
    let createTypedef ((n,ndt,a) : A.name) = 
      (*    E.s (error "doTypeDef") *)
      try
        let newTyp, tattr = 
          doType AttrType bt (A.PARENTYPE(attrs, ndt, a))  in
        let newTyp' = typeAddAttributes tattr newTyp in
        (* Create a new name for the type. Use the same name space as that of 
        * variables to avoid confusion between variable names and types. This 
        * is actually necessary in some cases.  *)
        let n' = newAlphaName true "" n in
        let namedTyp = TNamed(n', newTyp', []) in
        (* Register the type. register it as local because we might be in a 
        * local context  *)
        addLocalToEnv (kindPlusName "type" n) (EnvTyp namedTyp);
        theFile := GType (n', newTyp', !currentLoc) :: !theFile
      with e -> begin
        ignore (E.log "Error on A.TYPEDEF (%s)\n"
                  (Printexc.to_string e));
        theFile := GAsm ("booo_typedef:" ^ n, !currentLoc) :: !theFile
      end
    in
    List.iter createTypedef nl
  with e -> begin    
    ignore (E.log "Error on A.TYPEDEF (%s)\n"
              (Printexc.to_string e));
    let fstname = 
      match nl with
        [] -> "<missing name>"
      | (n, _, _) :: _ -> n
    in
    theFile := GAsm ("booo_typedef: " ^ fstname, !currentLoc) :: !theFile
  end

and doOnlyTypedef (specs: A.spec_elem list) : unit = 
  try
    let bt, sto, inl, attrs = doSpecList specs in
    if sto <> NoStorage || inl then 
      E.s (error "Storage or inline specifier not allowed in typedef");
    let restyp, nattr = doType AttrType bt (A.PARENTYPE(attrs, 
                                                        A.JUSTBASE, [])) in
    if nattr <> [] then
      ignore (warn "Ignoring identifier attribute");
           (* doSpec will register the type. Put a special GType in the file *)
    theFile := GType ("", restyp, !currentLoc) :: !theFile
  with e -> begin
    ignore (E.log "Error on A.ONLYTYPEDEF (%s)\n"
              (Printexc.to_string e));
    theFile := GAsm ("booo_typedef", !currentLoc) :: !theFile
  end

and assignInit (lv: lval) 
               (ie: init) 
               (iet: typ) 
               (acc: chunk) : chunk = 
  match ie with
    SingleInit e -> 
      let (_, e'') = castTo iet (typeOfLval lv) e in 
      acc +++ (Set(lv, e'', !currentLoc))
  | CompoundInit (t, initl) -> 
      foldLeftCompound
        (fun off i it acc -> 
          assignInit (addOffsetLval off lv) i it acc)
        t
        initl
        acc

  (* Now define the processors for body and statement *)
and doBody (b : A.body) : chunk = 
  enterScope ();
    (* Do the declarations and the initializers and the statements. *)
  let rec loop = function
      [] -> empty
    | A.BDEF d :: rest -> 
        let res = doDecl d in  (* !!! @ evaluates its arguments backwards *)
        res @@ loop rest
    | A.BSTM s :: rest -> 
        let res = doStatement s in
        res @@ loop rest
  in
  let res = afterConversion (loop b) in
  exitScope ();
  res
      
and doStatement (s : A.statement) : chunk = 
  try
    currentLoc := convLoc (A.get_statementloc s);
    match s with
      A.NOP _ -> skipChunk
    | A.COMPUTATION (e, loc) ->
        let (lasts, data) = !gnu_body_result in
        if lasts == s then begin      (* This is the last in a GNU_BODY *)
          let (s', e', t') = doExp false e (AExp None) in
          data := Some (e', t');      (* Record the result *)
          s'
        end else
          let (s', _, _) = doExp false e ADrop in
            (* drop the side-effect free expression *)
            (* And now do some peep-hole optimizations *)
          s'

    | A.BLOCK (b, loc) -> doBody b

    | A.SEQUENCE (s1, s2, loc) ->
        (doStatement s1) @@ (doStatement s2)

    | A.IF(e,st,sf,loc) ->
        let st' = doStatement st in
        let sf' = doStatement sf in
        doCondition e st' sf'

    | A.WHILE(e,s,loc) ->
        startLoop true;
        let s' = doStatement s in
        exitLoop ();
        loopChunk ((doCondition e skipChunk
                      (breakChunk !currentLoc))
                   @@ s')
          
    | A.DOWHILE(e,s,loc) -> 
        startLoop false;
        let s' = doStatement s in
        let s'' = consLabContinue (doCondition e skipChunk (breakChunk !currentLoc))
        in
        exitLoop ();
        loopChunk (s' @@ s'')
          
    | A.FOR(e1,e2,e3,s,loc) -> begin
        let (se1, _, _) = doExp false e1 ADrop in
        let (se3, _, _) = doExp false e3 ADrop in
        startLoop false;
        let s' = doStatement s in
        let s'' = consLabContinue se3 in
        exitLoop ();
        match e2 with
          A.NOTHING -> (* This means true *)
            se1 @@ loopChunk (s' @@ s'')
        | _ -> 
            se1 @@ loopChunk ((doCondition e2 skipChunk (breakChunk !currentLoc))
                              @@ s' @@ s'')
    end
    | A.BREAK loc -> breakChunk !currentLoc

    | A.CONTINUE loc -> continueOrLabelChunk !currentLoc

    | A.RETURN (A.NOTHING, loc) -> returnChunk None !currentLoc
    | A.RETURN (e, loc) -> 
        let (se, e', et) = doExp false e (AExp (Some !currentReturnType)) in
        let (et'', e'') = castTo et (!currentReturnType) e' in
        se @@ (returnChunk (Some e'') !currentLoc)
               
    | A.SWITCH (e, s, loc) -> 
        let (se, e', et) = doExp false e (AExp (Some intType)) in
        let (et'', e'') = castTo et intType e' in
        let s' = doStatement s in
        se @@ (switchChunk e'' s' !currentLoc)
               
    | A.CASE (e, s, loc) -> 
        let (se, e', et) = doExp false e (AExp None) in
        se @@ caseChunk (constFold e') !currentLoc (doStatement s)
                    
    | A.DEFAULT (s, loc) -> defaultChunk !currentLoc (doStatement s)
                     
    | A.LABEL (l, s, loc) -> 
        consLabel l (doStatement s)
                     
    | A.GOTO (l, loc) -> gotoChunk l !currentLoc
          
    | A.ASM (tmpls, isvol, outs, ins, clobs, loc) -> 
      (* Make sure all the outs are variables *)
        let temps : (lval * varinfo) list ref = ref [] in
        let stmts : chunk ref = ref empty in
        let outs' = 
          List.map 
            (fun (c, e) -> 
              let (se, e', t) = doExp false e (AExp None) in
              let lv = 
                match e' with Lval x -> x
                | _ -> E.s (error "Expected lval for ASM outputs")
              in
              stmts := !stmts @@ se;
              (c, lv)) outs 
        in
      (* Get the side-effects out of expressions *)
        let ins' = 
          List.map 
            (fun (c, e) -> 
              let (se, e', et) = doExp false e (AExp None) in
              stmts := !stmts @@ se;
              (c, e'))
            ins              
        in
        !stmts @@
        (i2c (Asm(tmpls, isvol, outs', ins', clobs, !currentLoc)))
  with e -> begin
    (ignore (E.log "Error in doStatement (%s)\n" (Printexc.to_string e)));
    consLabel "booo_statement" empty
  end



(* Translate a file *)
let convFile fname dl =
  ignore (E.log "Cabs2cil conversion\n");
  (* Clean up the global types *)
  E.hadErrors := false;
  theFile := [];
  H.clear compInfoNameEnv;
  (* Setup the built-ins *)
  let _ =
    let fdec = emptyFunction "__builtin_constant_p" in
    let argp  = makeLocalVar fdec "x" intType in
    fdec.svar.vtype <- TFun(intType, [ argp ], false, []);
    alphaConvertVarAndAddToEnv true fdec.svar
  in
  (* Now do the globals *)
  let doOneGlobal = function
      A.TYPEDEF (ng, loc) ->
        currentLoc := convLoc(loc);
        doTypedef ng

    | A.ONLYTYPEDEF (s, loc) ->
        currentLoc := convLoc(loc);
        doOnlyTypedef s

    | A.DECDEF ((s, nl), loc) ->
        currentLoc := convLoc(loc);
        List.iter (createGlobal s) nl

    | A.GLOBASM (s,loc) ->
        currentLoc := convLoc(loc);
        theFile := GAsm (s, !currentLoc) :: !theFile
    | A.PRAGMA (a, loc) -> begin
        currentLoc := convLoc(loc);
        match doAttr ("dummy", [a]) with
          [Attr("dummy", [a'])] ->
            let a'' =
              match a' with
                AId s -> Attr (s, [])
              | ACons (s, args) -> Attr (s, args)
              | _ -> E.s (error "Unexpected attribute in #pragma")
            in
            theFile := GPragma (a'', !currentLoc) :: !theFile
        | _ -> E.s (error "Too many attributes in pragma")
    end

    | A.FUNDEF (((specs,(n,dt,a)) : A.single_name),
               (body : A.body), loc) ->
        currentLoc := convLoc(loc);
        E.withContext
          (fun _ -> dprintf "2cil: %s" n)
          (fun _ ->
            try                    
             (* Reset the local identifier so that formals are created with 
              * the proper IDs  *)
              resetLocals ();
              (* Setup the environment. Add the formals to the locals. Maybe 
               * they need alpha-conv  *)
              enterScope ();  (* Start the scope *)

              let bt,sto,inl,attrs = doSpecList specs in
              let ftyp, funattr = doType (AttrName false) bt 
                                         (A.PARENTYPE(attrs, dt, a)) in
                                        (* Do the type *)
              let (returnType, formals, isvararg, funta) = 
                match unrollType ftyp with 
                  TFun(rType, formals, isvararg, a) -> 
                    (rType, formals, isvararg, a)
                | x -> E.s (error "non-function type: %a." d_type x)
              in
              (* Record the returnType for doStatement *)
              currentReturnType   := returnType;
              let formals' = 
                List.map (alphaConvertVarAndAddToEnv true) formals in
              let ftype = TFun(returnType, formals', isvararg, funta) in
              (* Add the function itself to the environment. Just in case we 
               * have recursion and no prototype.  *)
              (* Make a variable out of it and put it in the environment *)
              let thisFunctionVI, alreadyDef = 
                makeGlobalVarinfo 
                  { vname = n;
                    vtype = ftype;
                    vglob = true;
                    vid   = newVarId n true;
                    vdecl = lu;
                    vattr = funattr;
                    vaddrof = false;
                    vstorage = sto;
                    vreferenced = false;   (* sm *)
                  }
              in
(*              ignore (E.log "makefunvar:%s@! type=%a@! vattr=%a@!"
                        n d_plaintype ftype (d_attrlist true) funattr); *)
              if alreadyDef then
                E.s (error "There is a definition already for %s" n);
              currentFunctionVI := thisFunctionVI;
              (* Now do the body *)
              let stm = doBody body in
              (* Finish everything *)
              exitScope ();
              let (maxid, locals) = endFunction formals' in
              let fdec = { svar     = thisFunctionVI;
                           slocals  = locals;
                           sformals = formals';
                           smaxid   = maxid;
                           sbody    = mkFunctionBody stm;
                           sinline  = inl;
                         } 
              in
              setFormals fdec formals'; (* To make sure sharing is proper *)
(*              ignore (E.log "The env after finishing the body of %s:\n%t\n"
                        n docEnv); *)
              theFile := GFun (fdec, !currentLoc) :: !theFile
            with e -> begin
              ignore (E.log "error in collectFunction %s: %s\n" 
                        n (Printexc.to_string e));
              theFile := GAsm("error in function ", !currentLoc) :: !theFile
            end)
          () (* argument of E.withContext *)
  in
  List.iter doOneGlobal dl;
  (* We are done *)
  { fileName = fname;
    globals  = List.rev (! theFile);
    globinit = None;
    globinitcalled = false;
  } 


