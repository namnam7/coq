open Names
open Term
open Cbytecodes
open Copcodes
open Mod_subst

(* Relocation information *)
type reloc_info =
  | Reloc_annot of annot_switch 
  | Reloc_const of structured_constant
  | Reloc_getglobal of constant

type patch = reloc_info * int 

let patch_char4 buff pos c1 c2 c3 c4 = 
  String.unsafe_set buff pos       c1;
  String.unsafe_set buff (pos + 1) c2;
  String.unsafe_set buff (pos + 2) c3;
  String.unsafe_set buff (pos + 3) c4 
  
let patch_int buff pos n =
  patch_char4 buff pos 
    (Char.unsafe_chr n) (Char.unsafe_chr (n asr 8))  (Char.unsafe_chr (n asr 16))
    (Char.unsafe_chr (n asr 24))

(* Buffering of bytecode *)

let out_buffer = ref(String.create 1024)
and out_position = ref 0

let out_word b1 b2 b3 b4 =
  let p = !out_position in
  if p >= String.length !out_buffer then begin
    let len = String.length !out_buffer in
    let new_len =
      if len <= Sys.max_string_length / 2
      then 2 * len
      else
	if len = Sys.max_string_length
	then raise (Invalid_argument "String.create")  (* Pas la bonne execption
.... *)
	else Sys.max_string_length in
    let new_buffer = String.create new_len in
    String.blit !out_buffer 0 new_buffer 0 len;
    out_buffer := new_buffer
  end;
  patch_char4 !out_buffer p (Char.unsafe_chr b1)
   (Char.unsafe_chr b2) (Char.unsafe_chr b3) (Char.unsafe_chr b4);
  out_position := p + 4

let out opcode =
  out_word opcode 0 0 0

let out_int n =
  out_word n (n asr 8) (n asr 16) (n asr 24)

(* Handling of local labels and backpatching *)

type label_definition =
    Label_defined of int
  | Label_undefined of (int * int) list

let label_table  = ref ([| |] : label_definition array)
(* le ieme element de la table = Label_defined n signifie que l'on a 
   deja rencontrer le label i et qu'il est a l'offset n.
                               = Label_undefined l signifie que l'on a 
   pas encore rencontrer ce label, le premier entier indique ou est l'entier 
   a patcher dans la string, le deuxieme son origine  *)

let extend_label_table needed =
  let new_size = ref(Array.length !label_table) in
  while needed >= !new_size do new_size := 2 * !new_size done;
  let new_table = Array.create !new_size (Label_undefined []) in
  Array.blit !label_table 0 new_table 0 (Array.length !label_table);
  label_table := new_table

let backpatch (pos, orig) =
  let displ = (!out_position - orig) asr 2 in
  !out_buffer.[pos]   <- Char.unsafe_chr displ;
  !out_buffer.[pos+1] <- Char.unsafe_chr (displ asr 8);
  !out_buffer.[pos+2] <- Char.unsafe_chr (displ asr 16);
  !out_buffer.[pos+3] <- Char.unsafe_chr (displ asr 24)

let define_label lbl =
  if lbl >= Array.length !label_table then extend_label_table lbl;
  match (!label_table).(lbl) with
    Label_defined _ ->
      raise(Failure "CEmitcode.define_label")
  | Label_undefined patchlist ->
      List.iter backpatch patchlist;
      (!label_table).(lbl) <- Label_defined !out_position

let out_label_with_orig orig lbl =
  if lbl >= Array.length !label_table then extend_label_table lbl;
  match (!label_table).(lbl) with
    Label_defined def ->
      out_int((def - orig) asr 2)
  | Label_undefined patchlist ->
      (* spiwack: patchlist is supposed to be non-empty all the time
         thus I commented that out. If there is no problem I suggest
         removing it for next release (cur: 8.1) *)
      (*if patchlist = [] then *)
	(!label_table).(lbl) <-
          Label_undefined((!out_position, orig) :: patchlist);
      out_int 0

let out_label l = out_label_with_orig !out_position l

(* Relocation information *)

let reloc_info = ref ([] : (reloc_info * int) list)

let enter info =
  reloc_info := (info, !out_position) :: !reloc_info

let slot_for_const c =
  enter (Reloc_const c);
  out_int 0

and slot_for_annot a =
  enter (Reloc_annot a);
  out_int 0

and slot_for_getglobal id =
  enter (Reloc_getglobal id);
  out_int 0


(* Emission of one instruction *)


let emit_instr = function
  | Klabel lbl -> define_label lbl
  | Kacc n ->
      if n < 8 then out(opACC0 + n) else (out opACC; out_int n)
  | Kenvacc n ->
      if n >= 1 && n <= 4
      then out(opENVACC1 + n - 1)
      else (out opENVACC; out_int n)
  | Koffsetclosure ofs ->
      if ofs = -2 || ofs = 0 || ofs = 2
      then out (opOFFSETCLOSURE0 + ofs / 2)
      else (out opOFFSETCLOSURE; out_int ofs)
  | Kpush ->      
      out opPUSH
  | Kpop n ->      
      out opPOP; out_int n
  | Kpush_retaddr lbl -> 
      out opPUSH_RETADDR; out_label lbl
  | Kapply n ->
      if n < 4 then out(opAPPLY1 + n - 1) else (out opAPPLY; out_int n)
  | Kappterm(n, sz) ->
      if n < 4 then (out(opAPPTERM1 + n - 1); out_int sz)
               else (out opAPPTERM; out_int n; out_int sz)
  | Kreturn n ->
      out opRETURN; out_int n
  | Kjump ->
      out opRETURN; out_int 0
  | Krestart ->
      out opRESTART
  | Kgrab n -> 
      out opGRAB; out_int n
  | Kgrabrec(rec_arg) -> 
      out opGRABREC; out_int rec_arg
  | Kclosure(lbl, n) -> 
      out opCLOSURE; out_int n; out_label lbl
  | Kclosurerec(nfv,init,lbl_types,lbl_bodies) ->
      out opCLOSUREREC;out_int (Array.length lbl_bodies);
      out_int nfv; out_int init;
      let org = !out_position in
      Array.iter (out_label_with_orig org) lbl_types;
      let org = !out_position in
      Array.iter (out_label_with_orig org) lbl_bodies
  | Kclosurecofix(nfv,init,lbl_types,lbl_bodies) ->
      out opCLOSURECOFIX;out_int (Array.length lbl_bodies);
      out_int nfv; out_int init;
      let org = !out_position in
      Array.iter (out_label_with_orig org) lbl_types;
      let org = !out_position in
      Array.iter (out_label_with_orig org) lbl_bodies
  | Kgetglobal q -> 
      out opGETGLOBAL; slot_for_getglobal q
  | Kconst((Const_b0 i)) -> 
      if i >= 0 && i <= 3
          then out (opCONST0 + i)
          else (out opCONSTINT; out_int i) 
  | Kconst c ->
      out opGETGLOBAL; slot_for_const c
  | Kmakeblock(n, t) ->
      if n = 0 then raise (Invalid_argument "emit_instr : block size = 0")
      else if n < 4 then (out(opMAKEBLOCK1 + n - 1); out_int t)
      else (out opMAKEBLOCK; out_int n; out_int t)
  | Kmakeprod ->
      out opMAKEPROD
  | Kmakeswitchblock(typlbl,swlbl,annot,sz) ->
      out opMAKESWITCHBLOCK;
      out_label typlbl; out_label swlbl;
      slot_for_annot annot;out_int sz
  | Kswitch (tbl_const, tbl_block) ->
      let lenb = Array.length tbl_block in
      let lenc = Array.length tbl_const in
      assert (lenb < 0x100 && lenc < 0x1000000);
      out opSWITCH;
      out_word lenc (lenc asr 8) (lenc asr 16) (lenb);
(*      out_int (Array.length tbl_const + (Array.length tbl_block lsl 23)); *)
      let org = !out_position in
      Array.iter (out_label_with_orig org) tbl_const;
      Array.iter (out_label_with_orig org) tbl_block
  | Kpushfields n ->
      out opPUSHFIELDS;out_int n
  | Kfield n ->
      if n <= 1 then out (opGETFIELD0+n)
      else (out opGETFIELD;out_int n)
  | Ksetfield n ->
      if n <= 1 then out (opSETFIELD0+n) 
      else (out opSETFIELD;out_int n)
  | Ksequence _ -> raise (Invalid_argument "Cemitcodes.emit_instr")
  (* spiwack *)
  | Kbranch lbl -> out opBRANCH; out_label lbl
  | Kaddint31 -> out opADDINT31
  | Kaddcint31 -> out opADDCINT31
  | Kaddcarrycint31 -> out opADDCARRYCINT31
  | Ksubint31 -> out opSUBINT31
  | Ksubcint31 -> out opSUBCINT31
  | Ksubcarrycint31 -> out opSUBCARRYCINT31
  | Kmulint31 -> out opMULINT31
  | Kmulcint31 -> out opMULCINT31
  | Kdiv21int31 -> out opDIV21INT31
  | Kdivint31 -> out opDIVINT31
  | Kaddmuldivint31 -> out opADDMULDIVINT31
  | Kcompareint31 -> out opCOMPAREINT31
  | Khead0int31 -> out opHEAD0INT31
  | Ktail0int31 -> out opTAIL0INT31
  | Kisconst lbl -> out opISCONST; out_label lbl
  | Kareconst(n,lbl) -> out opARECONST; out_int n; out_label lbl
  | Kcompint31 -> out opCOMPINT31
  | Kdecompint31 -> out opDECOMPINT31
  (*/spiwack *)
  | Kstop -> 
      out opSTOP

(* Emission of a list of instructions. Include some peephole optimization. *)

let rec emit = function
  | [] -> ()
  (* Peephole optimizations *)
  | Kpush :: Kacc n :: c ->
      if n < 8 then out(opPUSHACC0 + n) else (out opPUSHACC; out_int n);
      emit c
  | Kpush :: Kenvacc n :: c -> 
      if n >= 1 && n <= 4
      then out(opPUSHENVACC1 + n - 1)
      else (out opPUSHENVACC; out_int n);
      emit c
  | Kpush :: Koffsetclosure ofs :: c -> 
      if ofs = -2 || ofs = 0 || ofs = 2
      then out(opPUSHOFFSETCLOSURE0 + ofs / 2)
      else (out opPUSHOFFSETCLOSURE; out_int ofs);
      emit c
  | Kpush :: Kgetglobal id :: c ->
      out opPUSHGETGLOBAL; slot_for_getglobal id; emit c 
  | Kpush :: Kconst (Const_b0 i) :: c -> 
      if i >= 0 && i <= 3
      then out (opPUSHCONST0 + i)
      else (out opPUSHCONSTINT; out_int i);
      emit c
  | Kpush :: Kconst const :: c ->
      out opPUSHGETGLOBAL; slot_for_const const;
      emit c 
  | Kpop n :: Kjump :: c ->
      out opRETURN; out_int n; emit c
  | Ksequence(c1,c2)::c ->
      emit c1; emit c2;emit c
  (* Default case *)
  | instr :: c ->
      emit_instr instr; emit c

(* Initialization *)

let init () =
  out_position := 0;
  label_table := Array.create 16 (Label_undefined []);
  reloc_info := []

type emitcodes = string

let length = String.length

type to_patch = emitcodes * (patch list) * fv

(* Substitution *)
let rec subst_strcst s sc =
  match sc with
  | Const_sorts _ | Const_b0 _ -> sc
  | Const_bn(tag,args) -> Const_bn(tag,Array.map (subst_strcst s) args)
  | Const_ind(ind) -> let kn,i = ind in Const_ind((subst_kn s kn, i))

let subst_patch s (ri,pos) = 
  match ri with
  | Reloc_annot a ->
      let (kn,i) = a.ci.ci_ind in
      let ci = {a.ci with ci_ind = (subst_kn s kn,i)} in
      (Reloc_annot {a with ci = ci},pos)
  | Reloc_const sc -> (Reloc_const (subst_strcst s sc), pos)
  | Reloc_getglobal kn -> (Reloc_getglobal (fst (subst_con s kn)), pos)

let subst_to_patch s (code,pl,fv) = 
  code,List.rev_map (subst_patch s) pl,fv

type body_code =
  | BCdefined of bool * to_patch
  | BCallias of constant
  | BCconstant

let subst_body_code s = function
  | BCdefined (b,tp) -> BCdefined (b,subst_to_patch s tp)
  | BCallias kn -> BCallias (fst (subst_con s kn))
  | BCconstant -> BCconstant

type to_patch_substituted = body_code substituted

let from_val = from_val

let force = force subst_body_code

let subst_to_patch_subst = subst_substituted 

let is_boxed tps =
  match tps with
  | None -> false
  | Some tps ->
    match force tps with
    | BCdefined(b,_) -> b
    | _ -> false

let to_memory (init_code, fun_code, fv) =
  init();
  emit init_code;
  emit fun_code;
  let code = String.create !out_position in
  String.unsafe_blit !out_buffer 0 code 0 !out_position;
  let reloc = List.rev !reloc_info in
  Array.iter (fun lbl -> 
    (match lbl with
      Label_defined _ -> assert true
    | Label_undefined patchlist -> 
	assert (patchlist = []))) !label_table;
  (code, reloc, fv)





