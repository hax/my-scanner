	.build_version macos, 15, 7, 9
	.file	1 "/opt/homebrew/Cellar/zig/0.16.0_1/lib/zig/std" "builtin.zig"
	.file	2 "/Users/bytedance/.cache/zig/b/0a6c00aa7362aa4ea449e9d80c0f9e4c" "builtin.zig"
	.section	__TEXT,__literal16,16byte_literals
	.p2align	4, 0x0
lCPI0_0:
	.byte	1
	.byte	2
	.byte	4
	.byte	8
	.byte	16
	.byte	32
	.byte	64
	.byte	128
	.byte	1
	.byte	2
	.byte	4
	.byte	8
	.byte	16
	.byte	32
	.byte	64
	.byte	128
	.section	__TEXT,__text,regular,pure_instructions
	.p2align	2
_mask.useCls32:
Lfunc_begin0:
	.file	3 "/Users/bytedance/r/my-scanner-oxc-neon/.exp" "mask.zig"
	.loc	3 41 0
	.cfi_startproc
	stp	x29, x30, [sp, #-16]!
	.cfi_def_cfa_offset 16
	mov	x29, sp
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
Ltmp0:
	.loc	3 22 31 prologue_end
	movi.16b	v0, #32
	ldp	q5, q6, [x0]
Ltmp1:
	cmeq.16b	v2, v6, v0
	cmeq.16b	v0, v5, v0
	.loc	3 22 81 is_stmt 0
	movi.16b	v1, #247
	add.16b	v3, v5, v1
	add.16b	v1, v6, v1
	movi.16b	v4, #5
	cmhi.16b	v7, v4, v1
	cmhi.16b	v1, v4, v3
	orr.16b	v1, v0, v1
	orr.16b	v3, v2, v7
Ltmp2:
	.loc	3 23 58 is_stmt 1
	movi.16b	v0, #208
	add.16b	v4, v5, v0
	add.16b	v0, v6, v0
	movi.16b	v7, #10
	cmhi.16b	v2, v7, v0
	cmhi.16b	v0, v7, v4
Ltmp3:
	.loc	3 26 5
	movi.16b	v4, #223
	and.16b	v7, v6, v4
	and.16b	v4, v5, v4
	movi.16b	v16, #191
	add.16b	v4, v4, v16
	add.16b	v7, v7, v16
	movi.16b	v16, #26
	cmhi.16b	v7, v16, v7
	cmhi.16b	v4, v16, v4
	.loc	3 26 57 is_stmt 0
	movi.16b	v16, #95
	cmeq.16b	v17, v5, v16
	cmeq.16b	v16, v6, v16
	.loc	3 26 81
	movi.16b	v18, #36
	cmeq.16b	v19, v6, v18
	.loc	3 26 57
	orr.16b	v16, v16, v19
	.loc	3 26 81
	cmeq.16b	v18, v5, v18
	.loc	3 26 57
	orr.16b	v17, v17, v18
	.loc	3 26 105
	cmlt.16b	v18, v5, #0
	cmlt.16b	v19, v6, #0
	.loc	3 26 81
	orr.16b	v16, v19, v16
	.loc	3 26 105
	orr.16b	v7, v16, v7
	.loc	3 26 81
	orr.16b	v16, v18, v17
	.loc	3 26 105
	orr.16b	v4, v16, v4
	orr.16b	v16, v0, v4
	orr.16b	v20, v2, v7
Ltmp4:
	.loc	3 27 31 is_stmt 1
	movi.16b	v7, #46
	cmeq.16b	v4, v5, v7
	cmeq.16b	v7, v6, v7
Ltmp5:
	.loc	3 28 57
	movi.16b	v17, #254
	and.16b	v21, v5, v17
	and.16b	v17, v6, v17
	movi.16b	v22, #60
	cmeq.16b	v17, v17, v22
	cmeq.16b	v21, v21, v22
	.loc	3 28 81 is_stmt 0
	movi.16b	v22, #62
	cmeq.16b	v23, v6, v22
	cmeq.16b	v22, v5, v22
	.loc	3 29 24 is_stmt 1
	movi.16b	v24, #43
	cmeq.16b	v25, v5, v24
	cmeq.16b	v24, v6, v24
	.loc	3 28 81
	orr.16b	v23, v24, v23
	.loc	3 29 24
	orr.16b	v17, v23, v17
	.loc	3 28 81
	orr.16b	v22, v25, v22
	.loc	3 29 24
	orr.16b	v21, v22, v21
	.loc	3 29 48 is_stmt 0
	movi.16b	v22, #45
	cmeq.16b	v23, v6, v22
	cmeq.16b	v22, v5, v22
	.loc	3 29 72
	movi.16b	v24, #42
	cmeq.16b	v25, v5, v24
	cmeq.16b	v24, v6, v24
	.loc	3 29 48
	orr.16b	v23, v24, v23
	orr.16b	v22, v25, v22
	.loc	3 30 24 is_stmt 1
	movi.16b	v24, #38
	cmeq.16b	v25, v6, v24
	cmeq.16b	v24, v5, v24
	.loc	3 29 72
	orr.16b	v22, v24, v22
	.loc	3 30 24
	orr.16b	v21, v22, v21
	.loc	3 29 72
	orr.16b	v22, v25, v23
	.loc	3 30 24
	orr.16b	v22, v22, v17
	.loc	3 30 48 is_stmt 0
	movi.16b	v17, #124
	cmeq.16b	v23, v5, v17
	cmeq.16b	v17, v6, v17
	.loc	3 30 72
	movi.16b	v24, #94
	cmeq.16b	v25, v6, v24
	cmeq.16b	v24, v5, v24
	.loc	3 30 48
	orr.16b	v23, v24, v23
	orr.16b	v17, v25, v17
	.loc	3 31 24 is_stmt 1
	movi.16b	v24, #33
	cmeq.16b	v25, v5, v24
	cmeq.16b	v24, v6, v24
	.loc	3 30 72
	orr.16b	v24, v24, v17
	orr.16b	v17, v25, v23
	.loc	3 31 48
	movi.16b	v23, #63
	cmeq.16b	v25, v6, v23
	cmeq.16b	v23, v5, v23
	.loc	3 31 24 is_stmt 0
	orr.16b	v17, v23, v17
	.loc	3 31 48
	orr.16b	v17, v17, v21
	.loc	3 31 24
	orr.16b	v21, v25, v24
	.loc	3 31 48
	orr.16b	v21, v21, v22
Ltmp6:
	.loc	3 32 33 is_stmt 1
	movi.16b	v22, #35
	cmeq.16b	v23, v5, v22
	cmeq.16b	v22, v6, v22
	.loc	3 32 57 is_stmt 0
	movi.16b	v24, #92
	cmeq.16b	v5, v5, v24
	cmeq.16b	v6, v6, v24
	orr.16b	v6, v22, v6
	orr.16b	v5, v23, v5
	.loc	3 32 82
	orr.16b	v5, v18, v5
	orr.16b	v18, v19, v6
Lloh0:
	adrp	x8, lCPI0_0@PAGE
Ltmp7:
	.loc	3 41 75 is_stmt 1
Lloh1:
	ldr	q6, [x8, lCPI0_0@PAGEOFF]
	and.16b	v19, v20, v6
	ext.16b	v20, v19, v19, #8
	zip1.16b	v19, v19, v20
	addv.8h	h19, v19
	str	h19, [x1, #2]
	and.16b	v16, v16, v6
	ext.16b	v19, v16, v16, #8
	zip1.16b	v16, v16, v19
	addv.8h	h16, v16
	str	h16, [x1]
	and.16b	v3, v3, v6
	ext.16b	v16, v3, v3, #8
	zip1.16b	v3, v3, v16
	addv.8h	h3, v3
	str	h3, [x1, #6]
	and.16b	v1, v1, v6
	ext.16b	v3, v1, v1, #8
	zip1.16b	v1, v1, v3
	addv.8h	h1, v1
	str	h1, [x1, #4]
	and.16b	v1, v2, v6
	ext.16b	v2, v1, v1, #8
	zip1.16b	v1, v1, v2
	addv.8h	h1, v1
	str	h1, [x1, #10]
	and.16b	v0, v0, v6
	ext.16b	v1, v0, v0, #8
	zip1.16b	v0, v0, v1
	addv.8h	h0, v0
	str	h0, [x1, #8]
	and.16b	v0, v7, v6
	ext.16b	v1, v0, v0, #8
	zip1.16b	v0, v0, v1
	addv.8h	h0, v0
	str	h0, [x1, #14]
	and.16b	v0, v4, v6
	ext.16b	v1, v0, v0, #8
	zip1.16b	v0, v0, v1
	addv.8h	h0, v0
	str	h0, [x1, #12]
	shl.16b	v0, v21, #7
	cmlt.16b	v0, v0, #0
	and.16b	v0, v0, v6
	ext.16b	v1, v0, v0, #8
	zip1.16b	v0, v0, v1
	addv.8h	h0, v0
	str	h0, [x1, #18]
	shl.16b	v0, v17, #7
	cmlt.16b	v0, v0, #0
	and.16b	v0, v0, v6
	ext.16b	v1, v0, v0, #8
	zip1.16b	v0, v0, v1
	addv.8h	h0, v0
	str	h0, [x1, #16]
	and.16b	v0, v18, v6
	ext.16b	v1, v0, v0, #8
	zip1.16b	v0, v0, v1
	addv.8h	h0, v0
	str	h0, [x1, #22]
	and.16b	v0, v5, v6
	ext.16b	v1, v0, v0, #8
	zip1.16b	v0, v0, v1
	addv.8h	h0, v0
	str	h0, [x1, #20]
	.cfi_def_cfa wsp, 16
	.loc	3 41 75 epilogue_begin is_stmt 0
	ldp	x29, x30, [sp], #16
	.cfi_def_cfa_offset 0
	.cfi_restore w30
	.cfi_restore w29
	ret
Ltmp8:
	.loh AdrpLdr	Lloh0, Lloh1
Lfunc_end0:
	.cfi_endproc

	.section	__TEXT,__literal16,16byte_literals
	.p2align	4, 0x0
lCPI1_0:
	.byte	1
	.byte	2
	.byte	4
	.byte	8
	.byte	16
	.byte	32
	.byte	64
	.byte	128
	.byte	1
	.byte	2
	.byte	4
	.byte	8
	.byte	16
	.byte	32
	.byte	64
	.byte	128
	.section	__TEXT,__text,regular,pure_instructions
	.p2align	2
_mask.useIdent:
Lfunc_begin1:
	.loc	3 40 0 is_stmt 1
	.cfi_startproc
	stp	x29, x30, [sp, #-16]!
	.cfi_def_cfa_offset 16
	mov	x29, sp
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	ldp	q0, q1, [x0]
Ltmp9:
	.loc	3 15 58 prologue_end
	movi.16b	v2, #208
	add.16b	v3, v1, v2
	add.16b	v2, v0, v2
	movi.16b	v4, #10
	cmhi.16b	v2, v4, v2
	cmhi.16b	v3, v4, v3
Ltmp10:
	.loc	3 16 33
	movi.16b	v4, #95
	cmeq.16b	v5, v1, v4
	cmeq.16b	v4, v0, v4
Ltmp11:
	.loc	3 17 34
	movi.16b	v6, #36
	cmeq.16b	v7, v0, v6
	cmeq.16b	v6, v1, v6
Ltmp12:
	.loc	3 18 5
	movi.16b	v16, #223
	and.16b	v0, v0, v16
	and.16b	v1, v1, v16
	movi.16b	v16, #191
	add.16b	v1, v1, v16
	add.16b	v0, v0, v16
	movi.16b	v16, #26
	cmhi.16b	v0, v16, v0
	cmhi.16b	v1, v16, v1
	orr.16b	v2, v4, v2
	orr.16b	v0, v2, v0
	orr.16b	v2, v5, v3
	orr.16b	v1, v2, v1
	orr.16b	v1, v6, v1
Lloh2:
	adrp	x8, lCPI1_0@PAGE
Lloh3:
	ldr	q2, [x8, lCPI1_0@PAGEOFF]
	and.16b	v1, v1, v2
	ext.16b	v3, v1, v1, #8
	zip1.16b	v1, v1, v3
	addv.8h	h1, v1
	fmov	w8, s1
	orr.16b	v0, v7, v0
	and.16b	v0, v0, v2
	ext.16b	v1, v0, v0, #8
	zip1.16b	v0, v0, v1
	addv.8h	h0, v0
	fmov	w0, s0
	bfi	w0, w8, #16, #16
Ltmp13:
	.cfi_def_cfa wsp, 16
	.loc	3 40 37 epilogue_begin
	ldp	x29, x30, [sp], #16
	.cfi_def_cfa_offset 0
	.cfi_restore w30
	.cfi_restore w29
	ret
Ltmp14:
	.loh AdrpLdr	Lloh2, Lloh3
Lfunc_end1:
	.cfi_endproc

	.section	__TEXT,__literal16,16byte_literals
	.p2align	4, 0x0
lCPI2_0:
	.byte	1
	.byte	2
	.byte	4
	.byte	8
	.byte	16
	.byte	32
	.byte	64
	.byte	128
	.byte	1
	.byte	2
	.byte	4
	.byte	8
	.byte	16
	.byte	32
	.byte	64
	.byte	128
	.section	__TEXT,__text,regular,pure_instructions
	.p2align	2
_mask.useWs:
Lfunc_begin2:
	.loc	3 39 0
	.cfi_startproc
	stp	x29, x30, [sp, #-16]!
	.cfi_def_cfa_offset 16
	mov	x29, sp
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	ldp	q1, q0, [x0]
Ltmp15:
	.loc	3 7 33 prologue_end
	movi.16b	v2, #32
	cmeq.16b	v3, v1, v2
	cmeq.16b	v2, v0, v2
Ltmp16:
	.loc	3 8 61
	movi.16b	v4, #247
	add.16b	v0, v0, v4
	add.16b	v1, v1, v4
	movi.16b	v4, #5
	cmhi.16b	v1, v4, v1
	cmhi.16b	v0, v4, v0
Ltmp17:
	.loc	3 9 5
	orr.16b	v0, v2, v0
Lloh4:
	adrp	x8, lCPI2_0@PAGE
Lloh5:
	ldr	q2, [x8, lCPI2_0@PAGEOFF]
	and.16b	v0, v0, v2
	ext.16b	v4, v0, v0, #8
	zip1.16b	v0, v0, v4
	addv.8h	h0, v0
	fmov	w8, s0
	orr.16b	v0, v3, v1
	and.16b	v0, v0, v2
	ext.16b	v1, v0, v0, #8
	zip1.16b	v0, v0, v1
	addv.8h	h0, v0
	fmov	w0, s0
	bfi	w0, w8, #16, #16
Ltmp18:
	.cfi_def_cfa wsp, 16
	.loc	3 39 34 epilogue_begin
	ldp	x29, x30, [sp], #16
	.cfi_def_cfa_offset 0
	.cfi_restore w30
	.cfi_restore w29
	ret
Ltmp19:
	.loh AdrpLdr	Lloh4, Lloh5
Lfunc_end2:
	.cfi_endproc

	.globl	_useCls32
_useCls32 = _mask.useCls32
	.globl	_useIdent
_useIdent = _mask.useIdent
	.globl	_useWs
_useWs = _mask.useWs
	.section	__DWARF,__debug_abbrev,regular,debug
Lsection_abbrev:
	.byte	1
	.byte	17
	.byte	1
	.byte	37
	.byte	14
	.byte	19
	.byte	5
	.byte	3
	.byte	14
	.byte	16
	.byte	23
	.byte	27
	.byte	14
	.ascii	"\341\177"
	.byte	25
	.byte	17
	.byte	1
	.byte	18
	.byte	6
	.byte	0
	.byte	0
	.byte	2
	.byte	52
	.byte	0
	.byte	3
	.byte	14
	.byte	73
	.byte	19
	.byte	58
	.byte	11
	.byte	59
	.byte	11
	.byte	110
	.byte	14
	.byte	0
	.byte	0
	.byte	3
	.byte	4
	.byte	1
	.byte	73
	.byte	19
	.byte	3
	.byte	14
	.byte	11
	.byte	11
	.byte	58
	.byte	11
	.byte	59
	.byte	5
	.ascii	"\210\001"
	.byte	15
	.byte	0
	.byte	0
	.byte	4
	.byte	40
	.byte	0
	.byte	3
	.byte	14
	.byte	28
	.byte	15
	.byte	0
	.byte	0
	.byte	5
	.byte	36
	.byte	0
	.byte	3
	.byte	14
	.byte	62
	.byte	11
	.byte	11
	.byte	11
	.byte	0
	.byte	0
	.byte	6
	.byte	46
	.byte	0
	.byte	110
	.byte	14
	.byte	3
	.byte	14
	.byte	58
	.byte	11
	.byte	59
	.byte	11
	.byte	73
	.byte	19
	.ascii	"\341\177"
	.byte	25
	.byte	32
	.byte	11
	.byte	0
	.byte	0
	.byte	7
	.byte	46
	.byte	1
	.byte	17
	.byte	1
	.byte	18
	.byte	6
	.byte	64
	.byte	24
	.byte	110
	.byte	14
	.byte	3
	.byte	14
	.byte	58
	.byte	11
	.byte	59
	.byte	11
	.byte	73
	.byte	19
	.ascii	"\341\177"
	.byte	25
	.byte	0
	.byte	0
	.byte	8
	.byte	5
	.byte	0
	.byte	2
	.byte	24
	.byte	3
	.byte	14
	.byte	58
	.byte	11
	.byte	59
	.byte	11
	.byte	73
	.byte	19
	.byte	0
	.byte	0
	.byte	9
	.byte	29
	.byte	0
	.byte	49
	.byte	19
	.byte	17
	.byte	1
	.byte	18
	.byte	6
	.byte	88
	.byte	11
	.byte	89
	.byte	11
	.byte	87
	.byte	11
	.byte	0
	.byte	0
	.byte	10
	.byte	46
	.byte	0
	.byte	110
	.byte	14
	.byte	3
	.byte	14
	.byte	58
	.byte	11
	.byte	59
	.byte	11
	.ascii	"\341\177"
	.byte	25
	.byte	32
	.byte	11
	.byte	0
	.byte	0
	.byte	11
	.byte	15
	.byte	0
	.byte	73
	.byte	19
	.byte	3
	.byte	14
	.byte	0
	.byte	0
	.byte	12
	.byte	1
	.byte	1
	.byte	73
	.byte	19
	.byte	3
	.byte	14
	.byte	0
	.byte	0
	.byte	13
	.byte	33
	.byte	0
	.byte	73
	.byte	19
	.byte	55
	.byte	11
	.byte	0
	.byte	0
	.byte	14
	.byte	36
	.byte	0
	.byte	3
	.byte	14
	.byte	11
	.byte	11
	.byte	62
	.byte	11
	.byte	0
	.byte	0
	.byte	0
	.section	__DWARF,__debug_info,regular,debug
Lsection_info:
Lcu_begin0:
Lset0 = Ldebug_info_end0-Ldebug_info_start0
	.long	Lset0
Ldebug_info_start0:
	.short	4
Lset1 = Lsection_abbrev-Lsection_abbrev
	.long	Lset1
	.byte	8
	.byte	1
	.long	0
	.short	12
	.long	11
Lset2 = Lline_table_start0-Lsection_line
	.long	Lset2
	.long	16

	.quad	Lfunc_begin0
Lset3 = Lfunc_end2-Lfunc_begin0
	.long	Lset3
	.byte	2
	.long	60
	.long	57
	.byte	2
	.byte	8
	.long	106
	.byte	3
	.long	90
	.long	72
	.byte	1
	.byte	1
	.short	862
	.byte	1
	.byte	4
	.long	94
	.byte	0
	.byte	4
	.long	98
	.byte	1
	.byte	4
	.long	102
	.byte	2
	.byte	0
	.byte	5
	.long	91
	.byte	7
	.byte	1
	.byte	6
	.long	126
	.long	147
	.byte	3
	.byte	21
	.long	113

	.byte	1
	.byte	5
	.long	163
	.byte	5
	.byte	0
	.byte	7
	.quad	Lfunc_begin0
Lset4 = Lfunc_end0-Lfunc_begin0
	.long	Lset4
	.byte	1
	.byte	109
	.long	177
	.long	168
	.byte	3
	.byte	41
	.long	113

	.byte	8
	.byte	1
	.byte	81
	.long	303
	.byte	3
	.byte	41
	.long	314
	.byte	9
	.long	97
	.quad	Ltmp0
Lset5 = Ltmp7-Ltmp0
	.long	Lset5
	.byte	3
	.byte	41
	.byte	75
	.byte	0
	.byte	10
	.long	191
	.long	210
	.byte	3
	.byte	12

	.byte	1
	.byte	7
	.quad	Lfunc_begin1
Lset6 = Lfunc_end1-Lfunc_begin1
	.long	Lset6
	.byte	1
	.byte	109
	.long	233
	.long	224
	.byte	3
	.byte	40
	.long	307

	.byte	9
	.long	183
	.quad	Ltmp9
Lset7 = Ltmp13-Ltmp9
	.long	Lset7
	.byte	3
	.byte	40
	.byte	57
	.byte	0
	.byte	10
	.long	247
	.long	267
	.byte	3
	.byte	6

	.byte	1
	.byte	7
	.quad	Lfunc_begin2
Lset8 = Lfunc_end2-Lfunc_begin2
	.long	Lset8
	.byte	1
	.byte	109
	.long	288
	.long	282
	.byte	3
	.byte	39
	.long	307

	.byte	9
	.long	245
	.quad	Ltmp15
Lset9 = Ltmp18-Ltmp15
	.long	Lset9
	.byte	3
	.byte	39
	.byte	55
	.byte	0
	.byte	5
	.long	299
	.byte	7
	.byte	4
	.byte	11
	.long	323
	.long	307
	.byte	12
	.long	307
	.long	315
	.byte	13
	.long	339
	.byte	6
	.byte	0
	.byte	14
	.long	322
	.byte	8
	.byte	7
	.byte	0
Ldebug_info_end0:
	.section	__DWARF,__debug_str,regular,debug
Linfo_string:
	.asciz	"zig 0.16.0"
	.asciz	"mask"
	.asciz	"/Users/bytedance/r/my-scanner-oxc-neon/.exp"
	.asciz	"output_mode"
	.asciz	"builtin.OutputMode"
	.asciz	"u2"
	.asciz	"Exe"
	.asciz	"Lib"
	.asciz	"Obj"
	.asciz	"builtin.output_mode"
	.asciz	"mask.classifyBlock32"
	.asciz	"classifyBlock32"
	.asciz	"void"
	.asciz	"useCls32"
	.asciz	"mask.useCls32"
	.asciz	"mask.identPartMask"
	.asciz	"identPartMask"
	.asciz	"useIdent"
	.asciz	"mask.useIdent"
	.asciz	"mask.whitespaceMask"
	.asciz	"whitespaceMask"
	.asciz	"useWs"
	.asciz	"mask.useWs"
	.asciz	"u32"
	.asciz	"out"
	.asciz	"*[6]u32"
	.asciz	"[6]u32"
	.asciz	"__ARRAY_SIZE_TYPE__"
	.section	__DWARF,__apple_names,regular,debug
Lnames_begin:
	.long	1212240712
	.short	1
	.short	0
	.long	12
	.long	12
	.long	12
	.long	0
	.long	1
	.short	1
	.short	6
	.long	0
	.long	-1
	.long	1
	.long	-1
	.long	-1
	.long	-1
	.long	3
	.long	-1
	.long	4
	.long	7
	.long	9
	.long	10
	.long	277150716
	.long	-1541221610
	.long	-749614538
	.long	-80906746
	.long	1312189148
	.long	-879799808
	.long	-854069000
	.long	-771163219
	.long	-87721543
	.long	-1180794498
	.long	1331797235
	.long	-886614605
Lset10 = LNames8-Lnames_begin
	.long	Lset10
Lset11 = LNames7-Lnames_begin
	.long	Lset11
Lset12 = LNames9-Lnames_begin
	.long	Lset12
Lset13 = LNames4-Lnames_begin
	.long	Lset13
Lset14 = LNames6-Lnames_begin
	.long	Lset14
Lset15 = LNames5-Lnames_begin
	.long	Lset15
Lset16 = LNames11-Lnames_begin
	.long	Lset16
Lset17 = LNames3-Lnames_begin
	.long	Lset17
Lset18 = LNames0-Lnames_begin
	.long	Lset18
Lset19 = LNames10-Lnames_begin
	.long	Lset19
Lset20 = LNames2-Lnames_begin
	.long	Lset20
Lset21 = LNames1-Lnames_begin
	.long	Lset21
LNames8:
	.long	282
	.long	1
	.long	257
	.long	0
LNames7:
	.long	191
	.long	1
	.long	224
	.long	0
LNames9:
	.long	288
	.long	1
	.long	257
	.long	0
LNames4:
	.long	224
	.long	1
	.long	195
	.long	0
LNames6:
	.long	210
	.long	1
	.long	224
	.long	0
LNames5:
	.long	233
	.long	1
	.long	195
	.long	0
LNames11:
	.long	247
	.long	1
	.long	286
	.long	0
LNames3:
	.long	126
	.long	1
	.long	162
	.long	0
LNames0:
	.long	168
	.long	1
	.long	120
	.long	0
LNames10:
	.long	267
	.long	1
	.long	286
	.long	0
LNames2:
	.long	147
	.long	1
	.long	162
	.long	0
LNames1:
	.long	177
	.long	1
	.long	120
	.long	0
	.section	__DWARF,__apple_objc,regular,debug
Lobjc_begin:
	.long	1212240712
	.short	1
	.short	0
	.long	1
	.long	0
	.long	12
	.long	0
	.long	1
	.short	1
	.short	6
	.long	-1
	.section	__DWARF,__apple_namespac,regular,debug
Lnamespac_begin:
	.long	1212240712
	.short	1
	.short	0
	.long	1
	.long	0
	.long	12
	.long	0
	.long	1
	.short	1
	.short	6
	.long	-1
	.section	__DWARF,__apple_types,regular,debug
Ltypes_begin:
	.long	1212240712
	.short	1
	.short	0
	.long	7
	.long	7
	.long	20
	.long	0
	.long	3
	.short	1
	.short	6
	.short	3
	.short	5
	.short	4
	.short	11
	.long	-1
	.long	0
	.long	1
	.long	2
	.long	3
	.long	4
	.long	-1
	.long	-594775205
	.long	2098800951
	.long	1001356800
	.long	5863820
	.long	193506143
	.long	2090838615
	.long	-534079251
Lset22 = Ltypes6-Ltypes_begin
	.long	Lset22
Lset23 = Ltypes4-Ltypes_begin
	.long	Lset23
Lset24 = Ltypes0-Ltypes_begin
	.long	Lset24
Lset25 = Ltypes1-Ltypes_begin
	.long	Lset25
Lset26 = Ltypes3-Ltypes_begin
	.long	Lset26
Lset27 = Ltypes2-Ltypes_begin
	.long	Lset27
Lset28 = Ltypes5-Ltypes_begin
	.long	Lset28
Ltypes6:
	.long	322
	.long	1
	.long	339
	.short	36
	.byte	0
	.long	0
Ltypes4:
	.long	307
	.long	1
	.long	314
	.short	15
	.byte	0
	.long	0
Ltypes0:
	.long	72
	.long	1
	.long	57
	.short	4
	.byte	0
	.long	0
Ltypes1:
	.long	91
	.long	1
	.long	90
	.short	36
	.byte	0
	.long	0
Ltypes3:
	.long	299
	.long	1
	.long	307
	.short	36
	.byte	0
	.long	0
Ltypes2:
	.long	163
	.long	1
	.long	113
	.short	36
	.byte	0
	.long	0
Ltypes5:
	.long	315
	.long	1
	.long	323
	.short	1
	.byte	0
	.long	0
.subsections_via_symbols
	.section	__DWARF,__debug_line,regular,debug
Lsection_line:
Lline_table_start0:
