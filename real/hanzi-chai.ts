import { cloneDeep } from "lodash-es";
import { 区间 } from "./bezier.js";
import type {
  向量,
  复合体数据,
  拼接部件数据,
  矢量图形数据,
  矢量笔画数据,
  结构描述字符,
  绘制,
} from "./data.js";
import { 加 } from "./math.js";

class 仿射变换 {
  static id = new 仿射变换(1, 1);
  static left = new 仿射变换(0.5, 1);
  static right = new 仿射变换(0.5, 1, [50, 0]);
  static top = new 仿射变换(1, 0.5);
  static bottom = new 仿射变换(1, 0.5, [0, 50]);
  static leftThird = new 仿射变换(0.33, 1);
  static centerThird = new 仿射变换(0.33, 1, [33, 0]);
  static rightThird = new 仿射变换(0.33, 1, [66, 0]);
  static topThird = new 仿射变换(1, 0.33);
  static middleThird = new 仿射变换(1, 0.33, [0, 33]);
  static bottomThird = new 仿射变换(1, 0.33, [0, 66]);
  static 查找表: Record<结构描述字符, 仿射变换[]> = {
    "⿰": [仿射变换.left, 仿射变换.right],
    "⿱": [仿射变换.top, 仿射变换.bottom],
    "⿲": [仿射变换.leftThird, 仿射变换.centerThird, 仿射变换.rightThird],
    "⿳": [仿射变换.topThird, 仿射变换.middleThird, 仿射变换.bottomThird],
    "⿴": [仿射变换.id, new 仿射变换(0.5, 0.5, [25, 25])],
    "⿵": [仿射变换.id, new 仿射变换(0.5, 0.5, [25, 40])],
    "⿶": [仿射变换.id, new 仿射变换(0.5, 0.5, [25, 10])],
    "⿷": [仿射变换.id, new 仿射变换(0.5, 0.5, [40, 25])],
    "⿸": [仿射变换.id, new 仿射变换(0.5, 0.5, [40, 40])],
    "⿹": [仿射变换.id, new 仿射变换(0.5, 0.5, [10, 40])],
    "⿺": [仿射变换.id, new 仿射变换(0.5, 0.5, [40, 10])],
    "⿼": [仿射变换.id, new 仿射变换(0.5, 0.5, [10, 25])],
    "⿽": [仿射变换.id, new 仿射变换(0.5, 0.5, [10, 10])],
    "⿻": [仿射变换.id, 仿射变换.id],
    "⿾": [仿射变换.id],
    "⿿": [仿射变换.id],
  };

  public constructor(
    private 横向缩放: number,
    private 纵向缩放: number,
    private 平移: 向量 = [0, 0],
  ) {}

  public 变换线段(动作: 绘制): 绘制 {
    const 新动作: 绘制 = cloneDeep(动作);
    switch (新动作.command) {
      case "h":
        新动作.parameterList[0] *= this.横向缩放;
        break;
      case "v":
        新动作.parameterList[0] *= this.纵向缩放;
        break;
      case "c":
      case "z":
        for (const index of [0, 2, 4] as const) {
          新动作.parameterList[index] *= this.横向缩放;
          新动作.parameterList[index + 1]! *= this.纵向缩放;
        }
        break;
    }
    return 新动作;
  }

  public 变换笔画(笔画: 矢量笔画数据): 矢量笔画数据 {
    const [x, y] = 笔画.start;
    const start = 加([x * this.横向缩放, y * this.纵向缩放] as 向量, this.平移);
    const 新笔画 = {
      ...笔画,
      start,
      curveList: 笔画.curveList.map((c) => this.变换线段(c)),
    };
    return 新笔画;
  }

  public 变换笔画列表(glyph: 矢量图形数据): 矢量图形数据 {
    return glyph.map((x) => this.变换笔画(x));
  }
}

class 图形盒子 {
  constructor(
    private 笔画列表: 矢量笔画数据[] = [],
    private 横向区间: 区间 = new 区间(0, 100),
    private 纵向区间: 区间 = new 区间(0, 100),
  ) {}

  获取笔画列表() {
    return this.笔画列表;
  }

  确定笔画粗细和视窗(displayMode: boolean) {
    const strokeWidthPercentage = displayMode ? 0.01 : 0.07;
    const xMin = this.横向区间.起点();
    const xMax = this.横向区间.终点();
    const yMin = this.纵向区间.起点();
    const yMax = this.纵向区间.终点();
    const padding = 10;
    const xSpan = xMax - xMin + 2 * padding;
    const ySpan = yMax - yMin + 2 * padding;
    const maxSpan = Math.max(xSpan, ySpan);
    const xMinFinal = (xMax + xMin) / 2 - maxSpan / 2;
    const yMinFinal = (yMax + yMin) / 2 - maxSpan / 2;
    const viewBox = `${xMinFinal} ${yMinFinal} ${maxSpan} ${maxSpan}`;
    const strokeWidth = maxSpan * strokeWidthPercentage;
    return { strokeWidth, viewBox };
  }

  static 从笔画列表构建(笔画列表: 矢量笔画数据[]) {
    let [xmin, ymin, xmax, ymax] = [
      Number.POSITIVE_INFINITY,
      Number.POSITIVE_INFINITY,
      Number.NEGATIVE_INFINITY,
      Number.NEGATIVE_INFINITY,
    ];
    for (const { start, curveList } of 笔画列表) {
      let [x, y] = start;
      xmin = Math.min(xmin, x);
      ymin = Math.min(ymin, y);
      xmax = Math.max(xmax, x);
      ymax = Math.max(ymax, y);
      for (const { command, parameterList } of curveList) {
        switch (command) {
          case "h":
            x += parameterList[0];
            break;
          case "v":
            y += parameterList[0];
            break;
          case "a":
            xmin = Math.min(xmin, x - parameterList[0]);
            xmax = Math.max(xmax, x + parameterList[0]);
            ymax = Math.max(ymax, y + 2 * parameterList[0]);
            break;
          default: {
            const [_x1, _y1, _x2, _y2, x3, y3] = parameterList;
            x += x3;
            y += y3;
            break;
          }
        }
        xmin = Math.min(xmin, x);
        ymin = Math.min(ymin, y);
        xmax = Math.max(xmax, x);
        ymax = Math.max(ymax, y);
      }
    }
    const x = new 区间(xmin, xmax);
    const y = new 区间(ymin, ymax);
    return new 图形盒子(笔画列表, x, y);
  }

  /**
   * 给定复合体数据和各部分渲染后的 SVG 图形，返回合并后的 SVG 图形
   * @param 数据 - 复合体数据 或 拼接部件数据
   * @param 部分列表 - 各部分渲染后的 SVG 图形
   * @returns 合并后的 SVG 图形
   */
  static 仿射合并(数据: 复合体数据 | 拼接部件数据, 部分列表: 图形盒子[]) {
    const { operator, order, parameters } = 数据;
    const 变换后图形列表: 矢量图形数据[] = [];
    let 新横向区间 = new 区间(0, 100);
    let 新纵向区间 = new 区间(0, 100);
    if (["⿰", "⿲", "⿱", "⿳"].includes(operator)) {
      // 上下、上中下、左右、左中右，直接拼接
      const 是左右结构 = ["⿰", "⿲"].includes(operator);
      for (const [
        index,
        { 笔画列表, 横向区间, 纵向区间 },
      ] of 部分列表.entries()) {
        if (index === 0) {
          变换后图形列表.push(structuredClone(笔画列表));
          新横向区间 = new 区间(横向区间.起点(), 横向区间.终点());
          新纵向区间 = new 区间(纵向区间.起点(), 纵向区间.终点());
          continue;
        }
        let 间隔 = 20;
        if (index === 1 && parameters?.gap2 !== undefined) {
          间隔 = parameters.gap2;
        } else if (index === 2 && parameters?.gap3 !== undefined) {
          间隔 = parameters.gap3;
        }
        const 主轴长度 = 是左右结构 ? 横向区间.长度() : 纵向区间.长度();
        const 区间增加 = 间隔 + 主轴长度;
        let 变换: 仿射变换;
        if (是左右结构) {
          const 横向平移 = 新横向区间.终点() + 间隔 - 横向区间.起点();
          变换 = new 仿射变换(1, 1, [横向平移, 0]);
          新横向区间.延长(区间增加);
          新纵向区间 = 新纵向区间.取并集(纵向区间);
        } else {
          const 纵向平移 = 新纵向区间.终点() + 间隔 - 纵向区间.起点();
          变换 = new 仿射变换(1, 1, [0, 纵向平移]);
          新纵向区间.延长(区间增加);
          新横向区间 = 新横向区间.取并集(横向区间);
        }
        变换后图形列表.push(变换.变换笔画列表(笔画列表));
      }
    } else {
      // 包围或结构，暂时还没有优化拼接的算法，用原来的仿射变换算法
      for (const [index, 变换] of 仿射变换.查找表[operator].entries()) {
        const 变换后图形 = 变换.变换笔画列表(部分列表[index]!.笔画列表);
        变换后图形列表.push(变换后图形);
      }
    }
    const 合并图形: 矢量图形数据 = [];
    if (order === undefined) {
      合并图形.push(...变换后图形列表.flat());
    } else {
      for (const { index, strokes } of order) {
        const 笔画列表 = 变换后图形列表[index];
        if (笔画列表 === undefined) continue;
        if (strokes === 0) {
          合并图形.push(...笔画列表);
        } else {
          合并图形.push(...笔画列表.slice(0, strokes));
          变换后图形列表[index] = 笔画列表.slice(strokes);
        }
      }
    }
    return new 图形盒子(合并图形, 新横向区间, 新纵向区间);
  }
}

export { 图形盒子 };

import type { 分类器 } from "./classifier.js";
import { 部件, type 默认部件分析 } from "./component.js";
import type { 星空键道复合体分析, 默认复合体分析 } from "./compound.js";
import {
  是归并,
  type 条件节点配置,
  type 构词规则,
  type 源节点配置,
  type 键盘配置,
} from "./config.js";
import {
  type 元素,
  取码器,
  type 拼音元素,
  type 自定义元素,
} from "./element.js";
import type { 拼音分析结果 } from "./pinyin.js";
import { 获取注册表 } from "./registry.js";
import type {
  动态字形分析结果,
  基本分析,
  基本复合体分析,
  基本部件分析,
  字形分析结果,
  带条件,
} from "./repertoire.js";
import { 优先表, 贝叶斯推断 } from "./repertoire.js";
import type { 字符 } from "./unicode.js";
import {
  default_err,
  ok,
  type Result,
  type 强类型元素位或编码,
  type 强类型决策,
  type 强类型决策空间,
  总序列化,
  排列组合,
  type 自定义分析映射,
} from "./utils.js";

/**
 * 代表了一个有字音、有字形的汉字的中间结果
 * 由拆分结果 [`ComponentResult`](#componentresult) 或 [`CompoundResult`](#compoundresult) 与字音组成
 */
type 默认汉字分析 = (默认部件分析 | 默认复合体分析) & {
  汉字: 字符;
  拼写运算: Map<string, 拼音元素>;
  自定义元素: Map<string, 自定义元素[]>;
};

interface 组装条目 {
  词: 字符[];
  拼音来源列表: string[][];
  元素序列: 元素序列;
  频率: number;
}

interface 动态组装条目 extends Omit<组装条目, "元素序列"> {
  元素序列: 优先表<元素序列>;
}

class 组词器 {
  constructor(private rules: 构词规则[]) {}

  static signedIndex = <T>(elements: T[], index: string) => {
    const order = index.codePointAt(0)! - "a".codePointAt(0)!;
    const signedOrder = order < 13 ? order : order - 26;
    return elements.at(signedOrder);
  };

  组词(全部码位: 元素序列[]) {
    const result: 强类型元素位或编码[] = [];
    let matched = false;
    for (const rule of this.rules) {
      if ("length_equal" in rule) {
        matched = 全部码位.length === rule.length_equal;
      } else if ("length_in_range" in rule) {
        matched =
          全部码位.length >= rule.length_in_range[0]! &&
          全部码位.length <= rule.length_in_range[1]!;
      }
      if (matched) {
        const tokens = Array.from(rule.formula);
        for (let i = 0; i < tokens.length; i = i + 2) {
          const charIndex = tokens[i]!.toLowerCase();
          const elementIndex = tokens[i + 1]!;
          const elements = 组词器.signedIndex(全部码位, charIndex);
          if (elements === undefined) continue;
          const element = 组词器.signedIndex(elements.元素序列, elementIndex);
          if (element === undefined) continue;
          result.push(element);
        }
        break;
      }
    }
    if (matched) return ok({ 元素序列: result });
    else return default_err("没有匹配的组词规则");
  }
}

interface 组装配置 {
  决策: 强类型决策;
  决策空间: 强类型决策空间;
  线性化决策: Map<元素, string>;
  源映射: Record<string, 源节点配置>;
  条件映射: Record<string, 条件节点配置>;
  构词规则列表: 构词规则[];
  最大码长: number;
  组装器?: string;
  键盘配置: 键盘配置;
  自定义分析映射: 自定义分析映射;
  分类器: 分类器;
}

interface 元素序列 {
  元素序列: 强类型元素位或编码[];
}

interface 组装器<
  部件分析 extends 基本分析 = 基本分析,
  复合体分析 extends 基本分析 = 基本分析,
> {
  一字词组装(
    汉字: 字符,
    字形分析: 部件分析 | 复合体分析,
    拼写运算: Map<string, 拼音元素>,
  ): Result<元素序列, Error>;

  多字词组装(
    词: 字符[],
    字形分析: (部件分析 | 复合体分析)[],
    拼写运算: Map<string, 拼音元素>[],
  ): Result<元素序列, Error>;
}

abstract class 按规则构词<
  A extends 基本分析 = 基本分析,
  B extends 基本分析 = 基本分析,
> implements 组装器<A, B>
{
  private 组词器: 组词器;
  constructor(配置: 组装配置) {
    this.组词器 = new 组词器(配置.构词规则列表);
  }

  abstract 一字词组装(
    汉字: 字符,
    字形分析: A | B,
    拼写运算: Map<string, 拼音元素>,
  ): Result<元素序列, Error>;

  多字词组装(
    词: 字符[],
    字形分析: (A | B)[],
    拼写运算: Map<string, 拼音元素>[],
  ) {
    const 汉字列表 = Array.from(词);
    const 全部元素序列: 元素序列[] = [];
    for (const [i, 汉字] of 汉字列表.entries()) {
      const 元素序列 = this.一字词组装(汉字, 字形分析[i]!, 拼写运算[i]!);
      if (!元素序列.ok) return 元素序列;
      全部元素序列.push(元素序列.value);
    }
    return this.组词器.组词(全部元素序列);
  }
}

class 默认组装器 extends 按规则构词 {
  static readonly type = "默认";
  private 取码器: 取码器;

  constructor(private 配置: 组装配置) {
    super(配置);
    this.取码器 = new 取码器(
      this.配置.决策,
      this.配置.决策空间,
      this.配置.线性化决策,
      this.配置.源映射,
      this.配置.条件映射,
      this.配置.最大码长,
      this.配置.分类器,
    );
  }

  一字词组装(
    汉字: 字符,
    字形分析: 默认部件分析 | 默认复合体分析,
    拼写运算: Map<string, 拼音元素>,
  ) {
    const 汉字分析: 默认汉字分析 = {
      汉字,
      拼写运算,
      ...字形分析,
      自定义元素: this.配置.自定义分析映射.get(汉字) ?? new Map(),
    };
    return ok({ 元素序列: this.取码器.取码(汉字分析) });
  }
}

class 星空键道组装器 extends 按规则构词<默认部件分析, 星空键道复合体分析> {
  static readonly type = "星空键道";
  constructor(private 配置: 组装配置) {
    super(配置);
  }

  编码长度(元素: 元素) {
    const 键盘映射 = this.配置.键盘配置.mapping;
    let value = 键盘映射[元素.获取名称()]!;
    while (是归并(value)) {
      value = 键盘映射[value.element]!;
    }
    return value.length;
  }

  一字词组装(
    _: 字符,
    字形分析: 默认部件分析 | 星空键道复合体分析,
    拼写运算: Map<string, 拼音元素>,
  ) {
    const 元素序列: 强类型元素位或编码[] = [
      { element: 拼写运算.get("键道声母")!, index: 0 },
      { element: 拼写运算.get("键道韵母")!, index: 0 },
    ];
    if ("首部字根序列" in 字形分析) {
      for (const 字根 of 字形分析.首部字根序列) {
        const 名称 = 字根 instanceof 部件 ? 字根.字符 : 字根;
        for (let i = 0; i < this.编码长度(名称); i++) {
          元素序列.push({ element: 名称, index: i });
        }
      }
      元素序列.splice(2 + 2); // 首部最多取两个形码
      for (const 字根 of 字形分析.余部字根序列) {
        const 名称 = 字根 instanceof 部件 ? 字根.字符 : 字根;
        for (let i = 0; i < this.编码长度(名称); i++) {
          元素序列.push({ element: 名称, index: i });
        }
      }
      元素序列.splice(2 + 4); // 一共最多取四个形码
    } else {
      for (const 字根 of 字形分析.字根序列) {
        const 名称 = 字根 instanceof 部件 ? 字根.字符 : 字根;
        for (let i = 0; i < this.编码长度(名称); i++) {
          元素序列.push({ element: 名称, index: i });
        }
      }
      元素序列.splice(2 + 4); // 一共最多取四个形码
    }
    return ok({ 元素序列: 元素序列 });
  }
}

const 组装 = (
  配置: 组装配置,
  拼音分析结果: 拼音分析结果,
  字形分析结果: 字形分析结果,
) => {
  const { 分析结果 } = 字形分析结果;
  const 组装结果: 组装条目[] = [];
  const 组装器 = 获取注册表().创建组装器(配置.组装器 || "默认", 配置)!;
  for (const { 词, 拼音, 频率, 元素映射 } of 拼音分析结果) {
    const 元素序列列表: 元素序列[] = [];
    if (词.length === 1) {
      const 字 = 词[0]!;
      for (const 字形分析 of 分析结果.get(字) ?? []) {
        const 元素序列 = 组装器.一字词组装(字, 字形分析!, 元素映射[0]!);
        if (!元素序列.ok) return 元素序列;
        元素序列列表.push(元素序列.value);
      }
    } else {
      const 各字字形分析: 基本分析[][] = [];
      for (const 字 of 词) {
        各字字形分析.push(分析结果.get(字) ?? []);
      }
      for (const 组合 of 排列组合(各字字形分析)) {
        const 元素序列 = 组装器.多字词组装(词, 组合, 元素映射);
        if (!元素序列.ok) return 元素序列;
        元素序列列表.push(元素序列.value);
      }
    }
    for (const 元素序列 of 元素序列列表) {
      组装结果.push({ 词, 元素序列, 频率, 拼音来源列表: [拼音] });
    }
  }
  const 去重后组装结果: 组装条目[] = [];
  const 索引映射 = new Map<string, number>();
  for (const 组装 of 组装结果) {
    const hash = `${组装.词.map((x) => x.获取名称()).join("")}:${总序列化(组装.元素序列.元素序列)}`;
    const 索引 = 索引映射.get(hash);
    if (索引 !== undefined) {
      const 上一个组装 = 去重后组装结果[索引]!;
      上一个组装.频率 += 组装.频率;
      上一个组装.拼音来源列表.push(...组装.拼音来源列表);
    } else {
      索引映射.set(hash, 去重后组装结果.length);
      去重后组装结果.push(组装);
    }
  }
  return ok(去重后组装结果);
};

const 动态组装 = (
  配置: 组装配置,
  拼音分析结果: 拼音分析结果,
  字形分析结果: 动态字形分析结果,
) => {
  const { 分析结果 } = 字形分析结果;
  const 组装结果: 动态组装条目[] = [];
  const 组装器 = 获取注册表().创建组装器(配置.组装器 || "默认", 配置)!;
  for (const { 词, 拼音, 频率, 元素映射 } of 拼音分析结果) {
    const 元素序列列表: 优先表<元素序列>[] = [];
    if (词.length === 1) {
      const 汉字 = 词[0]!;
      for (const 分析优先表 of 分析结果.get(汉字) ?? []) {
        const tmp: 带条件<元素序列>[] = [];
        for (const 字形分析 of 分析优先表) {
          const 元素序列 = 组装器.一字词组装(汉字, 字形分析, 元素映射[0]!);
          if (!元素序列.ok) continue;
          tmp.push({ ...元素序列.value, 条件列表: 字形分析.条件列表 });
        }
        元素序列列表.push(new 优先表(tmp));
      }
    } else {
      const 各字字形分析: (优先表<基本部件分析> | 优先表<基本复合体分析>)[][] =
        [];
      for (const 字 of 词) {
        各字字形分析.push(分析结果.get(字) ?? []);
      }
      for (const 组合 of 排列组合(各字字形分析)) {
        const tmp = 贝叶斯推断(
          组合.map((x) => [...x]),
          (组合一) => {
            const 组装值 = 组装器.多字词组装(词, 组合一, 元素映射);
            return 组装值.ok ? 组装值.value : { 元素序列: [] };
          },
        );
        元素序列列表.push(new 优先表(tmp));
      }
    }
    for (const 元素序列 of 元素序列列表) {
      组装结果.push({ 词, 元素序列, 频率, 拼音来源列表: [拼音] });
    }
  }
  const 去重后组装结果: 动态组装条目[] = [];
  const 索引映射 = new Map<string, number>();
  for (const 组装 of 组装结果) {
    const hash = `${组装.词.map((x) => x.获取名称()).join("")}:${[...组装.元素序列].map((x) => 总序列化(x.元素序列)).join(",")}`;
    const 索引 = 索引映射.get(hash);
    if (索引 !== undefined) {
      const 上一个组装 = 去重后组装结果[索引]!;
      上一个组装.频率 += 组装.频率;
      上一个组装.拼音来源列表.push(...组装.拼音来源列表);
    } else {
      索引映射.set(hash, 去重后组装结果.length);
      去重后组装结果.push(组装);
    }
  }
  return ok(去重后组装结果);
};

export type { 动态组装条目, 组装器, 组装条目, 组装配置, 默认汉字分析 };
export { 动态组装, 星空键道组装器, 组装, 默认组装器 };

import { isEqual } from "lodash-es";
import type { 笔画名称 } from "./classifier.js";
import type { 向量, 矢量笔画数据, 绘制 } from "./data.js";
import { 乘, 减, 加, 叉乘, 排序, 是共线, 距离, 除 } from "./math.js";

/**
 * 一段 Bezier 曲线的主要朝向
 * 例如，横笔画的朝向是水平的，竖笔画的朝向是垂直的
 * 而撇和捺笔画的朝向可能是水平或垂直的，取决于它是平撇还是撇、平捺还是捺
 */
type 朝向 = "horizontal" | "vertical";

interface 相交关系 {
  type: "交";
}

interface 相连关系 {
  type: "连";
  first: "前" | "中" | "后";
  second: "前" | "中" | "后";
}

const 构造相连 = (
  first: 相连关系["first"],
  second: 相连关系["second"],
): 相连关系 => ({ type: "连", first, second });

interface 平行离散关系 {
  type: "平行";
  mainAxis: 区间关系;
  crossAxis: 区间关系;
}

interface 垂直离散关系 {
  type: "垂直";
  x: 区间关系;
  y: 区间关系;
}

type 离散关系 = 平行离散关系 | 垂直离散关系;
type 曲线关系 = 相交关系 | 相连关系 | 离散关系;

abstract class 曲线 {
  abstract 获取类型(): "linear" | "cubic" | "arc";
  abstract 获取朝向(): 朝向;
  abstract 获取起点和终点(): [向量, 向量];
  abstract 求值(t: number): 向量;
  abstract 二分(): [曲线, 曲线];

  abstract _controls(): 向量[];

  获取区间(): [区间, 区间] {
    const [start, end] = this.获取起点和终点();
    const x = new 区间(start[0], end[0]);
    const y = new 区间(start[1], end[1]);
    return [x, y];
  }

  获取主轴和副轴区间(): [区间, 区间] {
    const [x, y] = this.获取区间();
    return this.获取朝向() === "horizontal" ? [x, y] : [y, x];
  }

  长度(): number {
    const [start, end] = this.获取起点和终点();
    return 距离(start, end);
  }

  是被区间包围(xrange: 区间, yrange: 区间): boolean {
    const [x, y] = this.获取区间();
    return xrange.包含(x) && yrange.包含(y);
  }

  计算关系(c: 曲线): 曲线关系 {
    const relation = this.计算相连关系(c);
    if (relation !== undefined) return relation;
    if (this instanceof 一次曲线 && c instanceof 一次曲线) {
      return this.计算线性一般关系(c);
    }
    return this.计算一般关系(c);
  }

  计算相连关系(c: 曲线): 相连关系 | undefined {
    const [astart, aend] = this.获取起点和终点();
    const [bstart, bend] = c.获取起点和终点();
    if (isEqual(astart, bstart)) return 构造相连("前", "前");
    if (isEqual(astart, bend)) return 构造相连("前", "后");
    if (isEqual(aend, bstart)) return 构造相连("后", "前");
    if (isEqual(aend, bend)) return 构造相连("后", "后");
    if (this.获取类型() === "linear") {
      if (是共线(astart, aend, bstart)) return 构造相连("中", "前");
      if (是共线(astart, aend, bend)) return 构造相连("中", "后");
    }
    if (c.获取类型() === "linear") {
      if (是共线(bstart, bend, astart)) return 构造相连("前", "中");
      if (是共线(bstart, bend, aend)) return 构造相连("后", "中");
    }
  }

  计算一般关系(c: 曲线): 曲线关系 {
    const 交点 = this.寻找交点(c);
    if (交点 === undefined) return this.计算离散关系(c);
    const [起点, 终点] = this.获取起点和终点();
    const [另一起点, 另一终点] = c.获取起点和终点();
    const 相连误差 = 3;
    if (距离(交点, 起点) < 相连误差) return 构造相连("前", "中");
    if (距离(交点, 终点) < 相连误差) return 构造相连("后", "中");
    if (距离(交点, 另一起点) < 相连误差) return 构造相连("中", "前");
    if (距离(交点, 另一终点) < 相连误差) return 构造相连("中", "后");
    return { type: "交" };
  }

  计算离散关系(c: 曲线): 离散关系 {
    if (this.获取朝向() === c.获取朝向()) {
      const [amain, across] = this.获取主轴和副轴区间();
      const [bmain, bcross] = c.获取主轴和副轴区间();
      return {
        type: "平行",
        mainAxis: amain.比较(bmain),
        crossAxis: across.比较(bcross),
      };
    } else {
      const [ax, ay] = this.获取区间();
      const [bx, by] = c.获取区间();
      return {
        type: "垂直",
        x: ax.比较(bx),
        y: ay.比较(by),
      };
    }
  }

  /**
   * 获取两个曲线在 t 取值上的交点
   */
  寻找交点(c: 曲线): 向量 | undefined {
    const [astart, aend] = this.获取起点和终点();
    const [bstart, bend] = c.获取起点和终点();
    const [axInterval, ayInterval] = this.获取区间();
    const [bxInterval, byInterval] = c.获取区间();
    const xposition = axInterval.比较(bxInterval);
    const yposition = ayInterval.比较(byInterval);
    const disjoint = [区间关系.先于, 区间关系.后于];
    if (disjoint.includes(xposition) || disjoint.includes(yposition))
      return undefined;
    const [alength, blength] = [距离(astart, aend), 距离(bstart, bend)];
    const threshold = 1;
    if (alength < threshold && blength < threshold)
      return 除(加(加(astart, aend), 加(bstart, bend)), 4);
    const [a_firsthalf, a_secondhalf] = this.二分();
    const [b_firsthalf, b_secondhalf] = c.二分();
    return (
      a_firsthalf.寻找交点(b_firsthalf) ||
      a_firsthalf.寻找交点(b_secondhalf) ||
      a_secondhalf.寻找交点(b_firsthalf) ||
      a_secondhalf.寻找交点(b_secondhalf)
    );
  }
}

/**
 * 一次 Bezier 曲线
 * 用于表示横、竖等笔画
 */
class 一次曲线 extends 曲线 {
  constructor(
    private orientation: 朝向,
    private controls: [向量, 向量],
  ) {
    super();
  }

  _controls(): 向量[] {
    return this.controls;
  }

  static 从绘制创建(start: 向量, draw: 绘制) {
    let p1: 向量;
    switch (draw.command) {
      case "h":
        p1 = 加(start, [draw.parameterList[0], 0]);
        break;
      default:
        p1 = 加(start, [0, draw.parameterList[0]]);
        break;
    }
    const orientation = draw.command === "v" ? "vertical" : "horizontal";
    return new 一次曲线(orientation, [start, p1]);
  }

  获取类型() {
    return "linear" as const;
  }
  获取朝向() {
    return this.orientation;
  }
  复制(): 一次曲线 {
    return new 一次曲线(this.orientation, structuredClone(this.controls));
  }

  二分(): [曲线, 曲线] {
    const mid = this.求值(0.5);
    const firstHalf = this.复制();
    const secondHalf = this.复制();
    firstHalf.controls[1] = mid;
    secondHalf.controls[0] = mid;
    return [firstHalf, secondHalf];
  }
  获取起点和终点(): [向量, 向量] {
    return [this.controls[0], this.controls[1]];
  }
  求值(t: number): 向量 {
    return 加(
      乘(1 - t, this.controls[0]) as 向量,
      乘(t, this.controls[1]) as 向量,
    );
  }

  计算线性一般关系(b: 一次曲线): 曲线关系 {
    const [astart, aend] = this.controls;
    const [bstart, bend] = b.controls;
    const [v, v1, v2] = [
      减(aend, astart),
      减(bstart, astart),
      减(bend, astart),
    ];
    const vc = 叉乘(v, v1) * 叉乘(v, v2);
    const [u, u1, u2] = [
      减(bend, bstart),
      减(astart, bstart),
      减(aend, bstart),
    ];
    const uc = 叉乘(u, u1) * 叉乘(u, u2);
    if (vc < 0 && uc < 0) {
      return { type: "交" };
    }
    return this.计算离散关系(b);
  }
}

/**
 * 三次 Bezier 曲线
 * 用于表示撇、捺等笔画
 */
class 三次曲线 extends 曲线 {
  constructor(
    private orientation: 朝向,
    private controls: [向量, 向量, 向量, 向量],
  ) {
    super();
  }

  _controls(): 向量[] {
    return this.controls;
  }

  static 从绘制创建(start: 向量, draw: 绘制) {
    const p1 = 加(start, draw.parameterList.slice(0, 2) as 向量);
    const p2 = 加(start, draw.parameterList.slice(2, 4) as 向量);
    const p3 = 加(start, draw.parameterList.slice(4) as 向量);
    const orientation = draw.command === "c" ? "vertical" : "horizontal";
    return new 三次曲线(orientation, [start, p1, p2, p3]);
  }
  获取类型() {
    return "cubic" as const;
  }
  获取朝向() {
    return this.orientation;
  }
  复制(): 三次曲线 {
    return new 三次曲线(this.orientation, structuredClone(this.controls));
  }
  获取起点和终点(): [向量, 向量] {
    return [this.controls[0], this.controls[3]];
  }
  二分(): [曲线, 曲线] {
    const [p0, p1, p2, p3] = this.controls;
    const p01 = 除(加(p0, p1), 2);
    const p12 = 除(加(p1, p2), 2);
    const p23 = 除(加(p2, p3), 2);
    const p012 = 除(加(p01, p12), 2);
    const p123 = 除(加(p12, p23), 2);
    const p0123 = 除(加(p012, p123), 2);
    const firstHalf = this.复制();
    const secondHalf = this.复制();
    firstHalf.controls = [p0, p01, p012, p0123];
    secondHalf.controls = [p0123, p123, p23, p3];
    return [firstHalf, secondHalf];
  }
  求值(t: number) {
    const v01 = 加(
      乘((1 - t) ** 3, this.controls[0]),
      乘(3 * (1 - t) ** 2 * t, this.controls[1]),
    );
    const v23 = 加(
      乘(3 * (1 - t) * t ** 2, this.controls[2]),
      乘(t ** 3, this.controls[3]),
    );
    return 加(v01, v23);
  }
}

/**
 * 圆弧曲线
 * 用于表示笔画「圈」
 */
class 圆弧曲线 extends 曲线 {
  constructor(
    private orientation: 朝向,
    private controls: [向量, 向量],
  ) {
    super();
  }

  _controls(): 向量[] {
    return this.controls;
  }

  static 从绘制创建(start: 向量, _: 绘制) {
    const orientation = "horizontal";
    return new 圆弧曲线(orientation, [start, start]);
  }

  获取类型() {
    return "arc" as const;
  }
  获取朝向() {
    return this.orientation;
  }
  求值(_: number): 向量 {
    return [0, 0];
  }
  获取起点和终点(): [向量, 向量] {
    return [this.controls[0], this.controls[1]];
  }
  二分(): [曲线, 曲线] {
    const mid = this.求值(0.5);
    const firstHalf = structuredClone(this);
    const secondHalf = structuredClone(this);
    firstHalf.controls[1] = mid;
    secondHalf.controls[0] = mid;
    return [firstHalf, secondHalf];
  }
}

const 创建曲线 = (start: 向量, draw: 绘制): 曲线 => {
  if (draw.command === "a") {
    return 圆弧曲线.从绘制创建(start, draw);
  }
  if (draw.command === "c" || draw.command === "z") {
    return 三次曲线.从绘制创建(start, draw);
  }
  return 一次曲线.从绘制创建(start, draw);
};

enum 区间关系 {
  先于 = -1,
  部分先于 = -0.5,
  重叠 = 0,
  部分后于 = 0.5,
  后于 = 1,
}

class 区间 {
  private start: number;
  private end: number;

  constructor(a: number, b: number) {
    [this.start, this.end] = 排序(a, b);
  }
  比较(other: 区间): 区间关系 {
    // totally disjoint
    if (this.end < other.start) return 区间关系.先于;
    if (this.start > other.end) return 区间关系.后于;
    // generally smaller or larger
    if (this.start < other.start && this.end < other.end)
      return 区间关系.部分先于;
    if (this.start > other.start && this.end > other.end)
      return 区间关系.部分后于;
    return 区间关系.重叠;
  }
  包含(other: 区间): boolean {
    return this.start <= other.start && this.end >= other.end;
  }
  长度(): number {
    return this.end - this.start;
  }
  取并集(other: 区间): 区间 {
    return new 区间(
      Math.min(this.start, other.start),
      Math.max(this.end, other.end),
    );
  }
  起点(): number {
    return this.start;
  }
  终点(): number {
    return this.end;
  }
  延长(amount: number) {
    this.end += amount;
  }
}

type 笔画关系 = 曲线关系[];

/**
 * 渲染后的笔画
 * 这个类型和 SVGStroke 的区别是，这个类型包含了一系列 Bezier 曲线，而 SVGStroke 包含了一系列 SVG 命令
 * Bezier 曲线里每一段的起点和终点都是显式写出的，所以比较适合于计算
 */
class 笔画图形 {
  feature: 笔画名称;
  curveList: 曲线[];

  constructor({ feature, start, curveList }: 矢量笔画数据) {
    this.feature = feature;
    this.curveList = [];
    let previousPosition = start;
    for (const draw of curveList) {
      const curve = 创建曲线(previousPosition, draw);
      previousPosition = curve.求值(1);
      this.curveList.push(curve);
    }
  }

  isBoundedBy(xrange: 区间, yrange: 区间): boolean {
    return this.curveList.every((x) => x.是被区间包围(xrange, yrange));
  }

  relation(stroke2: 笔画图形): 笔画关系 {
    const strokeRelation: 笔画关系 = [];
    for (const curve1 of this.curveList) {
      for (const curve2 of stroke2.curveList) {
        strokeRelation.push(curve1.计算关系(curve2));
      }
    }
    return strokeRelation;
  }
}

class 拓扑 {
  matrix: 笔画关系[][];
  orientedPairs: [number, number][];

  constructor(renderedGlyph: 笔画图形[]) {
    this.matrix = [];
    this.orientedPairs = [];
    for (const [index1, stroke1] of renderedGlyph.entries()) {
      const row: 笔画关系[] = [];
      for (const [index2, stroke2] of renderedGlyph.entries()) {
        if (index1 === index2) row.push([]);
        else row.push(stroke1.relation(stroke2));
      }
      this.matrix.push(row);
    }
    for (const [index1] of renderedGlyph.entries()) {
      for (const [index2] of renderedGlyph.entries()) {
        if (index2 >= index1) break;
        const relations = this.matrix[index1]![index2]!;
        if (relations.some((v) => v.type === "交" || v.type === "连")) continue;
        const parallelIndex = relations.findIndex(
          (v) => v.type === "平行" && v.mainAxis === 0,
        );
        if (parallelIndex !== -1) {
          this.orientedPairs.push([index1, index2]);
        }
      }
    }
  }
}

export type { 曲线关系, 笔画关系 };
export { 一次曲线, 三次曲线, 创建曲线, 区间, 圆弧曲线, 拓扑, 曲线, 笔画图形 };

import type { 绘制 } from "./data.js";

/**
 * 笔画名称参考 Unicode 中的 CJK 笔画块（共 38 种笔画）
 * 本系统共 41 种笔画，和 CJK 笔画的区别在于：
 * 1. U+31D2（P）称为平撇，而 U+31D3（SP）称为撇
 * 2. 仿照撇，在捺中分出了平捺、点中分出了平点
 * 3. 添加「特殊笔画」分类，用于表示一些无法归类的笔画
 * https://en.wikipedia.org/wiki/CJK_Strokes_(Unicode_block)
 * 分类参考 GF2001-2001 给出的笔画分类规范，将笔画分为 5 类，用数字表示
 */
const 默认分类器 = {
  横: 1,
  提: 1,
  竖: 2,
  竖钩: 2,
  撇: 3,
  平撇: 3,
  点: 4,
  平点: 4,
  捺: 4,
  平捺: 4,
  挑捺: 4,
  横钩: 5,
  横撇: 5,
  横折: 5,
  横折钩: 5,
  横斜钩: 5,
  横折提: 5,
  横折折: 5,
  横折弯: 5,
  横撇弯钩: 5,
  横折弯钩: 5,
  横斜弯钩: 5,
  横折折撇: 5,
  横折折折: 5,
  横折折折钩: 5,
  竖提: 5,
  竖折: 5,
  竖弯: 5,
  竖弯左: 5,
  竖弯钩: 5,
  竖折撇: 5,
  竖折折钩: 5,
  竖折折: 5,
  撇点: 5,
  撇折: 5,
  弯钩: 5,
  斜钩: 5,
  撇钩: 5,
  卧钩: 5,
  圈: 5,
  特殊笔画: 5,
};

/**
 * 给定方案配置文件中的不完整的分类器，将其与默认的分类器合并
 * 得到一个完整的分类器
 */
const 合并分类器 = (部分分类器?: Record<笔画名称, number>) => {
  return { ...默认分类器, ...(部分分类器 ?? {}) };
};

type 笔画名称 = keyof typeof 默认分类器;

type 分类器 = typeof 默认分类器;

/**
 * 特定类型的笔画在数据库中的表示所包含的 SVG 命令的类别和数量是固定的
 * 比如，横折折折钩的表示一定是 h v h v，不会有其他可能性
 * 另外，平撇、平点、平捺的命令是 z，这个不是规范的 SVG 命令，只是为了和撇、点、捺的 c 区分
 * z 和 c 的实际效果是一样的
 */
const 笔画表示方式: Record<笔画名称, 绘制["command"][]> = {
  横: ["h"],
  提: ["h"], // 美化：提
  竖: ["v"],
  竖钩: ["v"], // 美化：钩
  撇: ["c"],
  平撇: ["z"],
  点: ["c"],
  平点: ["z"],
  捺: ["c"],
  平捺: ["z"],
  挑捺: ["h", "c"],
  横钩: ["h"], // 美化：钩
  横撇: ["h", "c"],
  横折: ["h", "v"],
  横折钩: ["h", "v"], // 美化：钩
  横斜钩: ["h", "c"], // 美化：钩
  横折提: ["h", "v", "h"], // 美化：提
  横折折: ["h", "v", "h"],
  横折弯: ["h", "v", "h"],
  横撇弯钩: ["h", "c", "v"], // 美化：钩
  横折弯钩: ["h", "v", "h"], // 美化：钩
  横斜弯钩: ["h", "c"], // 美化：钩
  横折折撇: ["h", "v", "h", "c"],
  横折折折: ["h", "v", "h", "v"],
  横折折折钩: ["h", "v", "h", "v"], // 美化：钩
  竖提: ["v", "h"], // 美化：提
  竖折: ["v", "h"],
  竖弯: ["v", "h"],
  竖弯左: ["v", "h"],
  竖弯钩: ["v", "h"], // 美化：钩
  竖折撇: ["v", "h", "c"],
  竖折折钩: ["v", "h", "v"], // 美化：钩
  竖折折: ["v", "h", "v"],
  撇点: ["c", "c"],
  撇折: ["c", "h"],
  弯钩: ["v"], // 美化：钩
  斜钩: ["c"], // 美化：钩
  撇钩: ["c"], // 美化：钩
  卧钩: ["c"], // 美化：钩
  圈: ["a"],
  特殊笔画: ["c"],
};

export type { 分类器, 笔画名称 };
export { 合并分类器, 笔画表示方式, 默认分类器 };

import { bisectLeft, bisectRight } from "d3-array";
import { isEqual, range } from "lodash-es";
import { 区间, 拓扑, 笔画图形 } from "./bezier.js";
import type { 分类器, 笔画名称 } from "./classifier.js";
import type { 条件, 退化配置 } from "./config.js";
import type { 矢量图形数据, 结构描述字符 } from "./data.js";
import { 二笔, type 元素, 未知元素, 笔画 } from "./element.js";
import { 排序, 是共线, 是小于 } from "./math.js";
import { 获取注册表 } from "./registry.js";
import {
  优先表,
  type 基本部件分析,
  type 字形分析配置,
  type 字根,
  存在,
  type 带条件,
} from "./repertoire.js";
import type { 拆分方式, 拆分环境 } from "./selector.js";
import type { 字符 } from "./unicode.js";
import {
  default_err,
  ok,
  type Result,
  type 强类型安排描述,
  type 强类型条件,
  是强类型归并,
  type 源标签集合,
} from "./utils.js";

export const 默认退化配置: 退化配置 = {
  feature: {
    提: "横",
    捺: "点",
  } as Record<笔画名称, 笔画名称>,
  no_cross: false,
};

const 笔画名称等价 = (退化器: 退化配置, s1: 笔画名称, s2: 笔画名称) => {
  const 合并 = 退化器.feature ?? ({} as Record<笔画名称, 笔画名称>);
  const d1 = 合并[s1] ?? s1;
  const d2 = 合并[s2] ?? s2;
  return d1 === d2;
};

/**
 * 计算后的部件
 *
 * 在基本部件 BasicComponent 的基础上，将 SVG 命令转换为参数曲线
 * 再基于参数曲线计算拓扑
 */
class 部件 {
  private 笔画列表: 笔画图形[];
  private 拓扑: 拓扑;
  public 字形序号: number = 0;

  constructor(
    public 字符: 字符,
    public 标签集合: 源标签集合,
    public 兼容: boolean,
    public 矢量图形: 矢量图形数据,
  ) {
    this.笔画列表 = 矢量图形.map((x) => new 笔画图形(x));
    this.拓扑 = new 拓扑(this.笔画列表);
  }

  _笔画列表() {
    return this.笔画列表;
  }

  _拓扑() {
    return this.拓扑;
  }

  获取名称() {
    return this.字符.获取名称();
  }

  获取索引() {
    return this.字形序号 === 0
      ? `${this.获取名称()}`
      : `${this.获取名称()}-${this.字形序号}`;
  }

  笔画数() {
    return this.笔画列表.length;
  }

  获取笔画序列(classifier: 分类器) {
    return this.笔画列表.map((stroke) => classifier[stroke.feature]);
  }

  查询拓扑关系(i: number, j: number) {
    if (i <= j) {
      return this.拓扑.matrix[j]?.[i];
    } else {
      return this.拓扑.matrix[i]?.[j];
    }
  }

  具有同向笔画(i: number, j: number) {
    const [smaller, larger] = 排序(i, j);
    return this.拓扑.orientedPairs.some((x) => isEqual(x, [larger, smaller]));
  }

  /**
   * 给定一个部件和一个字根，找出这个部件所有包含这个字根的方式
   * 如果部件不包含这个字根，就返回空列表
   *
   * @param root - 字根
   * @param degenerator - 退化器
   */
  生成二进制切片列表(root: 部件, degenerator: 退化配置) {
    const { 笔画列表: cglyph, 拓扑: ctopology } = this;
    const { 笔画列表: rglyph, 拓扑: rtopology } = root;
    if (cglyph.length < rglyph.length) return [];
    let queue = [[]] as number[][];
    for (const [rIndex, rStroke] of rglyph.entries()) {
      const rStrokeTopology = rtopology.matrix[rIndex]?.slice(0, rIndex);
      const end = cglyph.length - rglyph.length + rIndex + 1;
      for (let _ = queue.length; _ !== 0; --_) {
        const indexList = queue.shift()!;
        const start = indexList.length ? indexList.at(-1)! + 1 : 0;
        for (const [cIndex, cStroke] of cglyph.slice(start, end).entries()) {
          if (!笔画名称等价(degenerator, cStroke.feature, rStroke.feature))
            continue;
          const realIndex = cIndex + start;
          const cStrokeTopology = ctopology.matrix[realIndex]?.filter((_, i) =>
            indexList.includes(i),
          );
          if (!isEqual(cStrokeTopology, rStrokeTopology)) continue;
          queue.push(indexList.concat(realIndex));
        }
      }
      if (!queue) return [];
    }
    if (degenerator.no_cross) {
      const allindices = [...Array(cglyph.length).keys()];
      queue = queue.filter((indices) => {
        const others = allindices.filter((x) => !indices.includes(x));
        const allCombinations = indices.flatMap((x) =>
          others.map((y) => 排序(x, y)),
        );
        return allCombinations.every(([x, y]) => {
          const relation = ctopology.matrix[y]![x]!;
          return relation.every((cr) => cr.type !== "交");
        });
      });
    }
    return queue
      .filter((x) => this.验证特殊字根(root, x))
      .map(this.索引转二进制.bind(this));
  }

  /**
   * 根据一个部件中包含的所有字根的情况，导出所有可能的拆分方案
   *
   * @param 全部字根二进制列表 - 部件包含的字根列表，其中每个字根用二进制表示
   * @param 必要字根二进制集合 - 部件必须包含的字根列表，其中每个字根用二进制表示
   * @param 二进制字根映射 - 从二进制表示到字根名称的映射
   *
   * 函数通过递归的方式，每次选取剩余部分的第一笔，然后在字根列表中找到包含这个笔画的所有字根
   * 将这些可能性与此前已经拆分的部分组合，得到新的拆分方案
   * 直到所有的笔画都使用完毕
   */
  生成拆分列表(
    全部字根二进制列表: number[],
    必要字根二进制集合: Set<number>,
    二进制字根映射: Map<number, 字根>,
    剪枝 = false,
  ) {
    const 拆分方式列表: 拆分方式[] = [];
    const 全部二进制 = (1 << this.笔画数()) - 1;
    const 区间和 = this.生成区间和(必要字根二进制集合);
    const 寻找下一个字根 = (
      部分和: number,
      拆分方式: number[],
      逆向累积和: number[],
    ) => {
      const 剩余和 = 全部二进制 - 部分和;
      const 剩余部分第一笔 = 1 << (31 - Math.clz32(剩余和));
      const 起始 = bisectLeft(全部字根二进制列表, 剩余部分第一笔);
      const 终止 = bisectRight(全部字根二进制列表, 剩余和);
      for (const 字根 of 全部字根二进制列表.slice(起始, 终止)) {
        if ((部分和 & 字根) !== 0) continue;
        const 新部分和 = 部分和 + 字根;
        const 新逆向累积和 = 逆向累积和.map((x) => x + 字根);
        const 新拆分方式 = 拆分方式.concat(字根);
        if (剪枝 && 新逆向累积和.some((x) => 区间和.has(x))) {
          continue;
        }
        新逆向累积和.push(字根);
        if (新部分和 === 全部二进制) {
          const res = 新拆分方式.map((v) => ({
            字根: 二进制字根映射.get(v)!,
            笔画索引: this.二进制转索引(v),
            笔画二进制表示: v,
          }));
          拆分方式列表.push(res);
        } else {
          寻找下一个字根(新部分和, 新拆分方式, 新逆向累积和);
        }
      }
    };
    寻找下一个字根(0, [], []);
    return 拆分方式列表;
  }

  生成区间和(字根集合: Set<number>) {
    const strokes = this.笔画数();
    const array = range(strokes)
      .map((x) => 1 << x)
      .reverse();
    const intervalSums = new Set<number>();
    for (let start = 0; start !== strokes - 1; ++start) {
      let sum = array[start]!;
      for (let end = start + 1; end !== strokes; ++end) {
        sum += array[end]!;
        if (字根集合.has(sum)) {
          intervalSums.add(sum);
        }
      }
    }
    return intervalSums;
  }

  索引转二进制(indices: number[]) {
    const n = this.笔画数();
    let binaryCode = 0;
    for (const index of indices) {
      binaryCode += 1 << (n - index - 1);
    }
    return binaryCode;
  }

  二进制转索引(binary: number) {
    const n = this.笔画数();
    const indices = [...Array(n).keys()];
    return indices.filter((index) => binary & (1 << (n - index - 1)));
  }

  /**
   * 对于一些特殊的字根，一般性的字根认同规则可能不足以区分它们，需要特殊处理
   * 这里判断了待拆分部件中的某些笔画究竟是不是这个字根
   *
   * @param root - 字根
   * @param indices - 笔画索引列表
   */
  验证特殊字根(root: 部件, indices: number[]) {
    const s = root.字符.获取名称();
    if (["土", "士"].includes(s)) {
      const [i1, _, i3] = indices as [number, number, number];
      const upperHeng = this.笔画列表[i1]!.curveList[0]!;
      const lowerHeng = this.笔画列表[i3]!.curveList[0]!;
      const lowerIsLonger = upperHeng.长度() < lowerHeng.长度();
      return s === "土" ? lowerIsLonger : !lowerIsLonger;
    }
    if (["未", "末"].includes(s)) {
      const [i1, i2] = indices as [number, number];
      const upperHeng = this.笔画列表[i1]!.curveList[0]!;
      const lowerHeng = this.笔画列表[i2]!.curveList[0]!;
      const lowerIsLonger = upperHeng.长度() < lowerHeng.长度();
      return s === "未" ? lowerIsLonger : !lowerIsLonger;
    }
    if (["口", "囗"].includes(s)) {
      if (["囗", "\ue02d"].includes(this.字符.获取名称())) {
        return s === "囗";
      }
      const [i1, _, i3] = indices as [number, number, number];
      const upperLeft = this.笔画列表[i1]!.curveList[0]!.求值(0);
      const lowerRight = this.笔画列表[i3]!.curveList[0]!.求值(1);
      const xrange = new 区间(upperLeft[0], lowerRight[0]);
      const yrange = new 区间(upperLeft[1], lowerRight[1]);
      const otherStrokes = this.笔画列表.filter(
        (_, index) => !indices.includes(index),
      );
      const containsStroke = otherStrokes.some((stroke) =>
        stroke.isBoundedBy(xrange, yrange),
      );
      return s === "囗" ? containsStroke : !containsStroke;
    }
    if (["\ue087" /* 木无十 */, "\ue43d" /* 全字头 */].includes(s)) {
      const [i1] = indices as [number];
      const attachPoint = this.笔画列表[i1]!.curveList[0]!.求值(0);
      const otherStrokes = this.笔画列表.filter(
        (_, index) => !indices.includes(index),
      );
      const otherCurves = otherStrokes.flatMap((s) => s.curveList);
      const pieAndNaIsSeparated = otherCurves.some(
        (x) =>
          x.获取类型() === "linear" &&
          是共线(x.求值(0), x.求值(1), attachPoint),
      );
      return s === "\ue087" ? pieAndNaIsSeparated : !pieAndNaIsSeparated;
    }
    return true;
  }

  生成二进制字根映射(字根部件列表: 部件[], 退化配置: 退化配置, 分类器: 分类器) {
    const 二进制字根映射 = new Map<number, 字根>(
      this.笔画列表.map((stroke, index) => {
        const 二进制数 = 1 << (this.笔画数() - 1 - index);
        return [二进制数, 笔画.创建(分类器[stroke.feature])];
      }),
    );
    for (const 字根部件 of 字根部件列表) {
      const 二进制列表 = this.生成二进制切片列表(字根部件, 退化配置);
      二进制列表.map((二进制数) => 二进制字根映射.set(二进制数, 字根部件));
    }
    return 二进制字根映射;
  }

  /**
   * 通过自动拆分算法，给定字根列表，对部件进行拆分
   * 如果拆分唯一，则返回拆分结果；否则返回错误
   *
   * @param 配置 - 拆分配置
   *
   * @returns 拆分结果或错误
   */
  给出部件分析(配置: 字形分析配置): Result<默认部件分析, Error> {
    const 当前字根 = new Set(配置.字根决策.keys());
    const 必要字根 = 当前字根.difference(配置.可选字根);
    const 退化配置 = 配置.退化配置;
    const 二进制字根映射 = this.生成二进制字根映射(
      配置.部件字根列表,
      退化配置,
      配置.分类器,
    );
    const 字根笔画索引映射 = new Map<字根, number[][]>();
    for (const [二进制数, 字根] of 二进制字根映射) {
      const 索引 = this.二进制转索引(二进制数);
      if (索引.length === 1) continue;
      if (!字根笔画索引映射.has(字根)) 字根笔画索引映射.set(字根, [索引]);
      else 字根笔画索引映射.get(字根)!.push(索引);
    }
    const 字根二进制列表 = Array.from(二进制字根映射.keys()).sort(
      (a, b) => a - b,
    );
    const 必要字根二进制集合: Set<number> = new Set();
    for (const [二进制数, 字根] of 二进制字根映射) {
      if (必要字根.has(字根)) 必要字根二进制集合.add(二进制数);
    }
    const 拆分方式列表 = this.生成拆分列表(
      字根二进制列表,
      必要字根二进制集合,
      二进制字根映射,
    );
    const 全部拆分方式 = this.选择(
      配置,
      拆分方式列表,
      二进制字根映射,
      必要字根,
    );
    const 当前拆分方式 = 全部拆分方式.find((x) =>
      x.拆分方式.every((y) => 当前字根.has(y.字根)),
    )!;
    if (当前拆分方式 === undefined) {
      return default_err("无法找到符合当前字根集合的拆分方式");
    }
    const 字根序列 = 当前拆分方式.拆分方式.map((x) => x.字根);
    return ok({
      类型: "部件" as const,
      字根序列,
      部件: this,
      字根笔画映射: 字根笔画索引映射,
      当前拆分方式,
      全部拆分方式,
    });
  }

  /**
   * 选择最优的拆分方案
   *
   * @param 配置 - 配置
   * @param 拆分方式列表 - 拆分方案列表
   * @param 二进制字根映射 - 字根映射，从切片的二进制表示到字根名称的映射
   */
  选择(
    配置: 字形分析配置,
    拆分方式列表: 拆分方式[],
    二进制字根映射: Map<number, 字根>,
    必要字根: Set<字根>,
  ): 拆分方式与评价[] {
    const environment: 拆分环境 = {
      部件图形: this,
      二进制字根映射,
      ...配置,
    };
    const 拆分方式与评价列表 = 拆分方式列表.map((拆分方式) => {
      const 评价: Map<string, number[]> = new Map();
      for (const [name, 筛选器] of 配置.筛选器列表) {
        const 取值 = 筛选器.评价(拆分方式, environment);
        评价.set(name, 取值);
      }
      return { 拆分方式, 评价, 可用: false };
    });
    拆分方式与评价列表.sort((a, b) => {
      for (const [name, _] of 配置.筛选器列表) {
        const aValue = a.评价.get(name)!;
        const bValue = b.评价.get(name)!;
        if (是小于(aValue, bValue)) return -1;
        if (是小于(bValue, aValue)) return 1;
      }
      return 0;
    });
    const 包含可选字根列表 = 拆分方式与评价列表.map((x) =>
      x.拆分方式.map((y) => y.字根).filter((y) => !必要字根.has(y)),
    );
    for (const [index, 拆分方式与评价] of 拆分方式与评价列表.entries()) {
      拆分方式与评价.可用 = true;
      for (let prevIndex = 0; prevIndex !== index; ++prevIndex) {
        const current = 包含可选字根列表[index]!;
        const previous = 包含可选字根列表[prevIndex]!;
        if (previous.every((x) => current.includes(x))) {
          拆分方式与评价.可用 = false;
          break;
        }
      }
      if (拆分方式与评价.拆分方式.every((x) => 必要字根.has(x.字根))) {
        break;
      }
    }
    return 拆分方式与评价列表;
  }
}

interface 拆分方式与评价 {
  拆分方式: 拆分方式;
  评价: Map<string, number[]>;
  可用: boolean;
}

abstract class 部件分析器<部件分析 extends 基本部件分析 = 基本部件分析> {
  /**
   * 分析部件并返回分析结果
   */
  分析(_: 部件): Result<部件分析, Error> {
    return default_err("分析未实现");
  }

  /**
   * 动态分析部件并返回分析结果组
   */
  动态分析(_: 部件): Result<优先表<部件分析>, Error> {
    return default_err("动态分析未实现");
  }
}

/**
 * 部件通过自动拆分算法分析得到的拆分结果的全部细节
 */
interface 默认部件分析 extends 基本部件分析 {
  字根笔画映射: Map<字根, number[][]>;
  当前拆分方式: 拆分方式与评价;
  全部拆分方式: 拆分方式与评价[];
  // 用于存储因为自定义而被覆盖的拆分方式
  被覆盖拆分方式?: 拆分方式与评价;
}

class 默认部件分析器 extends 部件分析器<默认部件分析> {
  static readonly type = "默认";
  constructor(private 配置: 字形分析配置) {
    super();
  }

  伪造当前拆分方式(_: 部件, 字根序列: 字根[]) {
    return {
      拆分方式: 字根序列.map((x) => ({
        字根: x,
        笔画索引: [0], // 为了让复合体执行笔顺能通过。
        笔画二进制表示: 0,
      })),
      评价: new Map(),
      可用: true,
    };
  }

  分析(部件: 部件) {
    const 如分析 = 部件.给出部件分析(this.配置);
    if (!如分析.ok) return 如分析;
    const 分析 = 如分析.value;
    const 自定义字根序列 = this.配置.自定义分析映射.get(部件);
    if (自定义字根序列 === undefined) return ok(分析);
    const 新分析: 默认部件分析 = {
      ...分析,
      字根序列: 自定义字根序列,
      被覆盖拆分方式: 分析.当前拆分方式,
    };
    // 尝试在所有拆分方式中找到与自定义字根序列完全匹配的一种，如果找到了，就把它设为当前拆分方式
    const 当前拆分方式 = 新分析.全部拆分方式.find((x) => {
      return isEqual(
        x.拆分方式.map((y) => y.字根.获取名称()),
        自定义字根序列.map((y) => y.获取名称()),
      );
    });
    新分析.当前拆分方式 =
      当前拆分方式 ?? this.伪造当前拆分方式(部件, 自定义字根序列);
    return ok(新分析);
  }

  动态分析(部件: 部件) {
    const 如分析 = 部件.给出部件分析(this.配置);
    if (!如分析.ok) return 如分析;
    const 基本分析 = 如分析.value;
    const 带条件分析列表: 带条件<默认部件分析>[] = 基本分析.全部拆分方式
      .filter((x) => x.可用)
      .map((x) => {
        const 字根序列 = x.拆分方式.map((y) => y.字根);
        const 可选字根集 = this.配置.可选字根.intersection(new Set(字根序列));
        const 条件列表: 条件[] = [...可选字根集].map(存在);
        return {
          ...基本分析,
          当前拆分方式: x,
          字根序列,
          条件列表,
        };
      });
    let 自定义字根序列列表 = this.配置.动态自定义分析映射.get(部件);
    if (自定义字根序列列表 === undefined) {
      const 自定义分析 = this.配置.自定义分析映射.get(部件);
      if (自定义分析) 自定义字根序列列表 = [自定义分析];
    }
    if (自定义字根序列列表 === undefined) return ok(new 优先表(带条件分析列表));
    const 定制化分析列表: 带条件<默认部件分析>[] = [];
    for (const 字根序列 of 自定义字根序列列表) {
      const 可选字根集 = this.配置.可选字根.intersection(new Set(字根序列));
      const 条件列表: 条件[] = [...可选字根集].map(存在);
      const 分析 = 带条件分析列表.find((x) =>
        isEqual(
          x.字根序列.map((y) => y.获取名称()),
          字根序列.map((y) => y.获取名称()),
        ),
      );
      if (分析) {
        定制化分析列表.push(分析);
      } else {
        const 假装分析: 带条件<默认部件分析> = {
          类型: "部件",
          部件,
          字根笔画映射: 基本分析.字根笔画映射,
          全部拆分方式: 基本分析.全部拆分方式,
          当前拆分方式: this.伪造当前拆分方式(部件, 字根序列),
          字根序列,
          条件列表,
        };
        定制化分析列表.push(假装分析);
      }
    }
    return ok(new 优先表(定制化分析列表));
  }
}

interface 首末取大部件分析 extends 基本部件分析 {
  正序取大字根序列: 字根[];
  逆序取大字根序列: 字根[];
}

class 首末取大部件分析器 extends 部件分析器<首末取大部件分析> {
  static readonly type = "首末取大";
  private 正序取大分析器: 默认部件分析器;
  private 逆序取大分析器: 默认部件分析器;

  constructor(private 配置: 字形分析配置) {
    super();
    const 注册表 = 获取注册表();
    const 正序取大配置: 字形分析配置 = {
      ...配置,
      筛选器列表: 配置.筛选器列表.map(([name, 筛选器]) => {
        if (name === "首末取大")
          return ["取大优先", 注册表.创建筛选器("取大优先")!];
        return [name, 筛选器];
      }),
    };
    const 逆序取大配置: 字形分析配置 = {
      ...配置,
      筛选器列表: 配置.筛选器列表.map(([name, 筛选器]) => {
        if (name === "首末取大")
          return ["倒序取大", 注册表.创建筛选器("倒序取大")!];
        return [name, 筛选器];
      }),
    };
    this.正序取大分析器 = new 默认部件分析器(正序取大配置);
    this.逆序取大分析器 = new 默认部件分析器(逆序取大配置);
  }

  分析(部件: 部件) {
    const 如结果 = 部件.给出部件分析(this.配置);
    if (!如结果.ok) return 如结果;
    const 分析 = 如结果.value;
    const 如正序取大分析 = this.正序取大分析器.分析(部件);
    if (!如正序取大分析.ok) return 如正序取大分析;
    const 如逆序取大分析 = this.逆序取大分析器.分析(部件);
    if (!如逆序取大分析.ok) return 如逆序取大分析;
    const 结果: 首末取大部件分析 = {
      ...分析,
      正序取大字根序列: 如正序取大分析.value.字根序列,
      逆序取大字根序列: 如逆序取大分析.value.字根序列,
    };
    return ok(结果);
  }
}

class 二笔部件分析器 extends 部件分析器<基本部件分析> {
  static readonly type = "二笔";
  constructor(private 配置: 字形分析配置) {
    super();
  }

  前两笔和末笔(部件: 部件) {
    const 笔画列表 = 部件.获取笔画序列(this.配置.分类器);
    const [第一笔, 第二笔] = 笔画列表;
    if (!第一笔) return default_err("部件没有笔画，无法进行二笔分析");
    const 字根序列: 字根[] = [二笔.创建(第一笔, 第二笔 ?? 0)];
    if (笔画列表.length > 2) {
      const 末笔 = 笔画列表.at(-1)!;
      字根序列.push(笔画.创建(末笔));
    }
    return ok(字根序列);
  }

  分析(部件: 部件) {
    const 结果: 基本部件分析 = { 类型: "部件", 字根序列: [], 部件 };
    if (this.配置.字根决策.has(部件)) {
      结果.字根序列.push(部件);
      return ok(结果);
    } else {
      const 前两笔和末笔 = this.前两笔和末笔(部件);
      if (!前两笔和末笔.ok) return 前两笔和末笔;
      结果.字根序列 = 前两笔和末笔.value;
      return ok(结果);
    }
  }

  动态分析(部件: 部件) {
    const 结果列表: 带条件<基本部件分析>[] = [];
    if (this.配置.字根决策.has(部件) || this.配置.可选字根.has(部件)) {
      const 条件列表 = this.配置.可选字根.has(部件) ? [存在(部件)] : [];
      结果列表.push({ 类型: "部件", 字根序列: [部件], 部件, 条件列表 });
    }
    const 是必要字根 =
      this.配置.字根决策.has(部件) && !this.配置.可选字根.has(部件);
    if (!是必要字根) {
      const 前两笔和末笔 = this.前两笔和末笔(部件);
      if (!前两笔和末笔.ok) return 前两笔和末笔;
      结果列表.push({
        类型: "部件",
        字根序列: 前两笔和末笔.value,
        部件,
        条件列表: [],
      });
    }
    return ok(new 优先表(结果列表));
  }
}

function 计算张码补码(
  字根序列: 字根[],
  分类器: 分类器,
  结构符?: 结构描述字符,
): 二笔 {
  // 在补码时，竖钩视为竖，横折弯钩视为折
  const 笔画合并 = [0, 1, 2, 3, 4, 5, 2, 5];
  const 首根笔顺 = 字根序列[0]!.获取笔画序列(分类器);
  const 末根笔顺 = 字根序列.at(-1)!.获取笔画序列(分类器);
  const 首根首笔 = 笔画合并[首根笔顺[0]!]!;
  const 末根末笔 = 笔画合并[末根笔顺.at(-1)!]!;
  // 单笔画补码用 61 表示
  if (字根序列.length === 1 && 首根笔顺.length === 1) {
    return 二笔.创建(6, 1);
  }
  // 并型和左下围，首 + 末；其他情况，末 + 首
  const 补码顺取 = /[⿰⿲⿺]/.test(结构符 ?? "");
  return 补码顺取
    ? 二笔.创建(首根首笔, 末根末笔)
    : 二笔.创建(末根末笔, 首根首笔);
}

interface 张码部件分析 extends 默认部件分析 {
  补码: 二笔;
  准码元: 未知元素;
}

class 张码部件分析器 extends 部件分析器<张码部件分析> {
  static readonly type = "张码";
  constructor(private 配置: 字形分析配置) {
    super();
  }

  伪造当前拆分方式(_: 部件, 字根序列: 字根[]) {
    return {
      拆分方式: 字根序列.map((x) => ({
        字根: x,
        笔画索引: [0], // 为了让复合体执行笔顺能通过。
        笔画二进制表示: 0,
      })),
      评价: new Map(),
      可用: true,
    };
  }

  添加张码特殊分析(分析: 默认部件分析) {
    const 补码 = 计算张码补码(分析.字根序列, this.配置.分类器);
    const 存在相交 = 分析.当前拆分方式.评价.get("能连不交")?.[0] ?? 0;
    const 准码元 = 分析.当前拆分方式.拆分方式.length === 2 && 存在相交 > 0;
    return ok({
      ...分析,
      补码,
      准码元: 准码元 ? new 未知元素("true") : new 未知元素("false"),
    });
  }

  分析(部件: 部件) {
    const 如分析 = 部件.给出部件分析(this.配置);
    if (!如分析.ok) return 如分析;
    const 分析 = 如分析.value;
    const 自定义字根序列 = this.配置.自定义分析映射.get(部件);
    if (自定义字根序列 === undefined) return this.添加张码特殊分析(分析);
    const 新分析: 默认部件分析 = {
      ...分析,
      字根序列: 自定义字根序列,
      被覆盖拆分方式: 分析.当前拆分方式,
    };
    // 尝试在所有拆分方式中找到与自定义字根序列完全匹配的一种，如果找到了，就把它设为当前拆分方式
    const 当前拆分方式 = 新分析.全部拆分方式.find((x) => {
      return isEqual(
        x.拆分方式.map((y) => y.字根.获取名称()),
        自定义字根序列.map((y) => y.获取名称()),
      );
    });
    新分析.当前拆分方式 =
      当前拆分方式 ?? this.伪造当前拆分方式(部件, 自定义字根序列);
    return this.添加张码特殊分析(新分析);
  }

  动态分析(_: 部件) {
    return default_err("动态分析未实现");
  }
}

interface 逸码拆分方式 {
  字根: 字根[];
  补码: 字根[];
}

interface 逸码部件分析 extends 基本部件分析 {
  余二拆分方式: 逸码拆分方式;
  余一拆分方式: 逸码拆分方式;
  笔画拆分方式: 逸码拆分方式;
}

class 逸码部件分析器 extends 部件分析器<逸码部件分析> {
  static readonly type = "逸码";
  constructor(private 配置: 字形分析配置) {
    super();
  }

  private 限制字根数量(拆分方式: 拆分方式, n: number, 图形: 部件) {
    const get = (i: number) =>
      二笔.创建(this.配置.分类器[图形._笔画列表()[i]!.feature]!, 0);
    const 新拆分方式 = {
      字根: 拆分方式.slice(0, n).map((x) => x.字根),
      补码: [] as 字根[],
    };
    if (拆分方式.length <= n) {
      for (const 笔画 of 拆分方式.at(-1)!.笔画索引) {
        新拆分方式.补码.push(get(笔画));
      }
      while (新拆分方式.补码.length < 6) {
        新拆分方式.补码.push(新拆分方式.补码.at(-1)!);
      }
    } else {
      const 全部笔画 = range(图形.笔画数());
      const 已用笔画 = new Set(拆分方式.slice(0, n).flatMap((x) => x.笔画索引));
      const 未用笔画 = 全部笔画.filter((x) => !已用笔画.has(x));
      未用笔画.map((x) => 新拆分方式.字根.push(get(x)));
      while (新拆分方式.补码.length < 6) {
        新拆分方式.补码.push(新拆分方式.字根.at(-1)!);
      }
    }
    return 新拆分方式;
  }

  private 自定义限制字根数量(字根序列: 字根[], n: number) {
    const 新拆分方式 = {
      字根: 字根序列.slice(0, n),
      补码: [] as 字根[],
    };
    if (字根序列.length <= n) {
      for (const 笔画 of 字根序列.at(-1)!.获取笔画序列(this.配置.分类器)) {
        新拆分方式.补码.push(二笔.创建(笔画, 0));
      }
      while (新拆分方式.补码.length < 6) {
        新拆分方式.补码.push(新拆分方式.补码.at(-1)!);
      }
    } else {
      const 未用笔画 = 字根序列
        .slice(n)
        .flatMap((x) => x.获取笔画序列(this.配置.分类器));
      未用笔画.map((x) => 新拆分方式.字根.push(二笔.创建(x, 0)));
      while (新拆分方式.补码.length < 6) {
        新拆分方式.补码.push(新拆分方式.字根.at(-1)!);
      }
    }
    return 新拆分方式;
  }

  分析(部件: 部件) {
    const 可选分析 = 部件.给出部件分析(this.配置);
    if (!可选分析.ok) return 可选分析;
    // TODO: 这里没有定制化
    const 分析 = 可选分析.value;
    let 余二拆分方式: 逸码拆分方式,
      余一拆分方式: 逸码拆分方式,
      笔画拆分方式: 逸码拆分方式;
    const 拆分方式 = 分析.当前拆分方式.拆分方式;
    if (
      isEqual(
        拆分方式.map((x) => x.字根),
        分析.字根序列,
      )
    ) {
      余二拆分方式 = this.限制字根数量(拆分方式, 2, 部件);
      余一拆分方式 = this.限制字根数量(拆分方式, 1, 部件);
      笔画拆分方式 = this.限制字根数量(拆分方式, 0, 部件);
    } else {
      余二拆分方式 = this.自定义限制字根数量(分析.字根序列, 2);
      余一拆分方式 = this.自定义限制字根数量(分析.字根序列, 1);
      笔画拆分方式 = this.自定义限制字根数量(分析.字根序列, 0);
    }
    const result = {
      ...分析,
      字根序列: 余二拆分方式.字根.concat(余二拆分方式.补码),
      余二拆分方式,
      余一拆分方式,
      笔画拆分方式,
    };
    return ok(result);
  }
}

interface 冰雪飞花部件分析 extends 默认部件分析 {
  全集合当前拆分方式: 拆分方式与评价;
  全集合字根序列: 字根[];
}

class 冰雪飞花分析器 {
  public 可选字根 = new Set<字根>();
  public 可选字根与必要一般字根 = new Set<字根>();
  public 小集合 = /[eiuoav;/]/;

  证明该字根只会出现在小集合(元素: 元素) {
    const 全部安排列表: 强类型安排描述[] = [];
    全部安排列表.push(...(this.配置.决策空间.get(元素) ?? []));
    const 当前安排 = this.配置.决策.get(元素);
    if (当前安排)
      全部安排列表.push({ value: 当前安排, score: 0, condition: [] });
    for (const { condition, value } of 全部安排列表) {
      if (typeof value === "string") {
        if (!this.小集合.test(value)) return false;
      } else if (是强类型归并(value)) {
        const 归并字根 = value.element;
        const 归并限制 =
          condition?.some((x) =>
            isEqual(x, {
              element: value.element,
              op: "是",
              value: "a",
            } satisfies 强类型条件),
          ) ?? false;
        if (!归并限制 && !this.证明该字根只会出现在小集合(归并字根))
          return false;
      } else if (Array.isArray(value)) {
        const c1 = value[0]!;
        if (!(typeof c1 === "object" && "variable" in c1)) return false;
        if (c1.variable !== "小集合") return false;
      } else {
        return false;
      }
    }
    return true;
  }

  在小集合(字根: 字根) {
    const 条件: 条件 = {
      element: 字根.获取名称(),
      op: "是" as const,
      value: "a",
    };
    return 条件;
  }

  当前在小集合(字根: 字根) {
    const 元素 = 字根 instanceof 部件 ? 字根.字符 : 字根;
    return this.小集合.test(this.配置.线性化决策.get(元素) ?? "");
  }

  private constructor(private 配置: 字形分析配置) {
    // this.可选字根：可选小集合字根、可选一般字根
    // this.配置.可选字根：必要一般字根、可选小集合字根、可选一般字根
    this.可选字根 = new Set(配置.可选字根);
    this.可选字根与必要一般字根 = new Set(配置.可选字根);
    for (const [字根] of 配置.字根决策.entries()) {
      const 元素 = 字根 instanceof 部件 ? 字根.字符 : 字根;
      if (!this.证明该字根只会出现在小集合(元素)) {
        this.可选字根与必要一般字根.add(字根);
      }
    }
    // const 必要字根 = new Set(配置.字根决策.keys()).difference(this.可选字根与必要一般字根);
  }

  static 创建(配置: 字形分析配置): 冰雪飞花分析器 {
    return new 冰雪飞花分析器(配置);
  }
}

class 冰雪飞花部件分析器 extends 部件分析器<冰雪飞花部件分析> {
  static readonly type = "冰雪飞花";
  private 分析器: 冰雪飞花分析器;

  constructor(private 配置: 字形分析配置) {
    super();
    this.分析器 = 冰雪飞花分析器.创建(配置);
  }

  给出真实或自定义分析(部件: 部件) {
    const 如分析 = 部件.给出部件分析({
      ...this.配置,
      可选字根: this.分析器.可选字根与必要一般字根,
    });
    if (!如分析.ok) return 如分析;
    const 分析 = 如分析.value;
    const 自定义字根序列 = this.配置.动态自定义分析映射.get(部件);
    if (自定义字根序列 === undefined) return ok(分析);
    const 新分析: 默认部件分析 = {
      ...分析,
      全部拆分方式: 自定义字根序列.map((字根序列) => {
        return {
          拆分方式: 字根序列.map((x) => ({
            字根: x,
            笔画索引: [0], // 为了让复合体执行笔顺能通过。
            笔画二进制表示: 0,
          })),
          评价: new Map(),
          可用: true,
        };
      }),
    };
    return ok(新分析);
  }

  分析(部件: 部件) {
    const 分析 = this.给出真实或自定义分析(部件);
    if (!分析.ok) return 分析;
    const { 当前拆分方式, 字根序列, ...rest } = 分析.value;
    const 实际拆分方式 = rest.全部拆分方式.find((x) =>
      x.拆分方式.every((y) => this.分析器.当前在小集合(y.字根)),
    );
    const 全字根当前拆分方式 = rest.全部拆分方式.find(
      (x) =>
        (x.拆分方式.length === 1 &&
          this.配置.字根决策.has(x.拆分方式[0]!.字根)) ||
        x.拆分方式.every((y) => this.分析器.当前在小集合(y.字根)),
    );
    if (!实际拆分方式 || !全字根当前拆分方式) {
      return default_err("无法找到符合当前字根名称的拆分方式");
    }
    const 新分析: 冰雪飞花部件分析 = {
      ...rest,
      当前拆分方式: 实际拆分方式,
      字根序列: 实际拆分方式.拆分方式.map((y) => y.字根).slice(0, 3),
      全集合当前拆分方式: 全字根当前拆分方式,
      全集合字根序列: 全字根当前拆分方式.拆分方式
        .map((y) => y.字根)
        .slice(0, 3),
    };
    return ok(新分析);
  }

  动态分析(部件: 部件) {
    const 分析 = this.给出真实或自定义分析(部件);
    if (!分析.ok) return 分析;
    const { 当前拆分方式, 字根序列, ...rest } = 分析.value;
    const 全集合分析列表: 带条件<默认部件分析>[] = [];
    const 小集合分析列表: 带条件<默认部件分析>[] = [];
    const 可用拆分方式列表 = rest.全部拆分方式.filter((x) => x.可用);
    let 考虑全集合 = true;
    for (const 拆分方式 of 可用拆分方式列表) {
      const 小集合分析: 带条件<默认部件分析> = {
        ...rest,
        当前拆分方式: 拆分方式,
        字根序列: 拆分方式.拆分方式.map((y) => y.字根).slice(0, 3),
        条件列表: [],
      };
      // 对于小集合拆分，所有涉及到的元素必须都在小集合
      for (const { 字根 } of 拆分方式.拆分方式) {
        if (this.分析器.可选字根与必要一般字根.has(字根)) {
          小集合分析.条件列表.push(this.分析器.在小集合(字根));
        }
      }
      小集合分析列表.push(小集合分析);
      if (!考虑全集合) continue;
      const 全集合分析: 带条件<默认部件分析> = {
        ...rest,
        当前拆分方式: 拆分方式,
        字根序列: 拆分方式.拆分方式.map((y) => y.字根).slice(0, 3),
        条件列表: [],
      };
      if (全集合分析.字根序列.length === 1) {
        const 字根 = 全集合分析.字根序列[0]!;
        if (this.分析器.可选字根.has(字根)) {
          全集合分析.条件列表.push(存在(字根));
        } else {
          考虑全集合 = false;
        }
      } else {
        for (const { 字根 } of 拆分方式.拆分方式) {
          if (this.分析器.可选字根.has(字根)) {
            全集合分析.条件列表.push(存在(字根));
          }
        }
      }
      全集合分析列表.push(全集合分析);
    }
    const a = new 优先表(小集合分析列表) as any;
    a.__magic = new 优先表(全集合分析列表);
    return ok(a);
  }
}

export type {
  冰雪飞花部件分析,
  张码部件分析,
  拆分方式与评价,
  逸码拆分方式,
  逸码部件分析,
  部件分析器,
  首末取大部件分析,
  默认部件分析,
};
export {
  二笔部件分析器,
  冰雪飞花分析器,
  冰雪飞花部件分析器,
  张码部件分析器,
  计算张码补码,
  逸码部件分析器,
  部件,
  首末取大部件分析器,
  默认部件分析器,
};

import { range, sortBy } from "lodash-es";
import type { 分类器, 笔画名称 } from "./classifier.js";
import {
  冰雪飞花分析器,
  type 冰雪飞花部件分析,
  type 张码部件分析,
  计算张码补码,
  type 逸码部件分析,
  部件,
  type 首末取大部件分析,
  type 默认部件分析,
} from "./component.js";
import type { 笔画块, 结构描述字符 } from "./data.js";
import { 二笔, 未知元素, 结构符元素 } from "./element.js";
import {
  优先表,
  type 基本复合体分析,
  type 基本部件分析,
  type 字形,
  type 字形分析配置,
  type 字根,
  存在,
  type 带条件,
  是复合体,
  是部件,
  贝叶斯推断,
} from "./repertoire.js";
import type { 字符 } from "./unicode.js";
import { default_err, ok, type Result, type 源标签集合 } from "./utils.js";

class 复合体 {
  private 笔画列表: 笔画名称[];

  constructor(
    public 字符: 字符,
    public 标签集合: 源标签集合,
    public 兼容: boolean,
    public 结构描述字符: 结构描述字符,
    public 部分列表: 字形[],
    public 笔顺: 笔画块[],
  ) {
    this.笔画列表 = this.计算笔画列表(笔顺, 部分列表);
  }

  /**
   * 将复合体递归渲染为 SVG 图形
   *
   * @param compound - 复合体
   * @param repertoire - 原始字符集
   *
   * @returns SVG 图形或错误
   */
  计算笔画列表(笔顺: 笔画块[], 部分列表: 字形[]): 笔画名称[] {
    const 各部分笔画列表: 笔画名称[][] = [];
    for (const 字形 of 部分列表) {
      if (字形 instanceof 部件) {
        各部分笔画列表.push(字形.矢量图形.map((x) => x.feature));
      } else {
        各部分笔画列表.push(字形.笔画列表);
      }
    }
    const merged: 笔画名称[] = [];
    for (const { index, strokes } of 笔顺) {
      const seq = 各部分笔画列表[index];
      if (seq === undefined) continue;
      if (strokes === 0) {
        merged.push(...seq);
      } else {
        merged.push(...seq.slice(0, strokes));
        各部分笔画列表[index] = seq.slice(strokes);
      }
    }
    return merged;
  }

  按首笔排序部分(): 字形[] {
    const 部分列表 = sortBy(range(this.部分列表.length), (i) =>
      this.笔顺.findIndex((b) => b.index === i),
    ).map((i) => this.部分列表[i]!);
    return 部分列表;
  }

  获取笔画序列(classifier: 分类器) {
    return this.笔画列表.map((f) => classifier[f]);
  }
}

type 字根序列与条件 = 带条件<{ 字根序列: 字根[] }>;

abstract class 复合体分析器<
  部件分析 extends 基本部件分析 = 基本部件分析,
  复合体分析 extends 基本复合体分析 = 基本复合体分析,
> {
  public 部件分析结果: Map<部件, 部件分析> = new Map();
  public 动态部件分析结果: Map<部件, 优先表<部件分析>> = new Map();

  constructor(protected 配置: 字形分析配置) {}

  查找部件分析结果(部件: 部件): 部件分析 | undefined {
    return this.部件分析结果.get(部件);
  }

  查找动态部件分析结果(部件: 部件): 优先表<部件分析> | undefined {
    return this.动态部件分析结果.get(部件);
  }

  顺序取根(字形: 字形): 字根[] {
    if (是部件(字形)) return this.查找部件分析结果(字形)!.字根序列;
    const 字根 = this.配置.复合体字根映射.get(字形);
    if (字根 !== undefined && this.配置.字根决策.has(字根)) return [字根];
    const 部分结果列表 = 字形.部分列表.map((子字形) => {
      let 字根序列: 字根[];
      let 部件分析: 部件分析 | undefined;
      if (是部件(子字形)) {
        部件分析 = this.查找部件分析结果(子字形);
        字根序列 = 部件分析!.字根序列;
      } else 字根序列 = this.顺序取根(子字形);
      return { 字根序列, 部件分析 };
    });
    const result = this.执行笔顺(部分结果列表, 字形.笔顺);
    return result;
  }

  动态顺序取根(字形: 字形): 字根序列与条件[] {
    if (是部件(字形)) {
      return [...this.查找动态部件分析结果(字形)!];
    }
    const 结果列表: 带条件<{ 字根序列: 字根[] }>[] = [];
    const 字根 = this.配置.复合体字根映射.get(字形);
    if (字根 !== undefined) {
      const 条件列表 = this.配置.可选字根.has(字根) ? [存在(字根)] : [];
      结果列表.push({
        字根序列: [字根],
        条件列表,
      });
      if (!this.配置.可选字根.has(字根)) return 结果列表;
    }
    const 部分结果组列表 = 字形.部分列表.map((子字形) => {
      const 部分结果组 = [];
      if (是部件(子字形)) {
        for (const 分析 of this.查找动态部件分析结果(子字形)!) {
          部分结果组.push({
            字根序列: 分析.字根序列,
            部件分析: 分析,
            条件列表: 分析.条件列表,
          });
        }
      } else {
        const 动态结果 = this.动态顺序取根(子字形);
        for (const { 字根序列, 条件列表 } of 动态结果) {
          部分结果组.push({ 字根序列, 部件分析: undefined, 条件列表 });
        }
      }
      return 部分结果组;
    });
    return 结果列表.concat(
      贝叶斯推断(部分结果组列表, (组合) => {
        const 字根序列 = this.执行笔顺(组合, 字形.笔顺);
        return { 字根序列 };
      }),
    );
  }

  执行笔顺(
    部分结果列表: {
      字根序列: 字根[];
      部件分析?: 部件分析;
    }[],
    笔顺: 笔画块[],
  ): 字根[] {
    const 已取笔画数列表 = 部分结果列表.map(() => 0);
    const 字根序列: 字根[] = [];
    const 剩余字根序列列表 = 部分结果列表.map((x) => [...x.字根序列]);
    for (const { index, strokes } of 笔顺) {
      const 剩余部分 = 部分结果列表[index];
      const 剩余部分字根序列 = 剩余字根序列列表[index];
      if (剩余部分 === undefined || 剩余部分字根序列 === undefined) continue; // 忽略无效部分
      const 部件分析 = 剩余部分.部件分析;
      if (
        strokes === 0 ||
        部件分析 === undefined ||
        !("当前拆分方式" in 部件分析)
      ) {
        字根序列.push(...剩余部分字根序列);
        剩余字根序列列表[index] = [];
      } else {
        const { 当前拆分方式 } = 部件分析 as any as 默认部件分析;
        const toTake = 当前拆分方式.拆分方式.filter(
          (x) =>
            x.笔画索引[0]! >= 已取笔画数列表[index]! &&
            x.笔画索引[0]! <= 已取笔画数列表[index]! + strokes - 1,
        ).length;
        字根序列.push(...剩余部分字根序列.slice(0, toTake));
        剩余字根序列列表[index] = 剩余部分字根序列.slice(toTake);
        已取笔画数列表[index]! += strokes;
      }
    }
    return 字根序列;
  }

  /**
   * 对复合体分析并返回分析结果
   */
  分析(_: 复合体): Result<复合体分析, Error> {
    return default_err("分析未实现");
  }

  /**
   * 对复合体进行动态分析并返回分析结果组
   */
  动态分析(_: 复合体): Result<优先表<复合体分析>, Error> {
    return default_err("动态分析未实现");
  }
}

export interface 默认复合体分析 extends 基本复合体分析 {
  结构: 结构符元素;
}

class 默认复合体分析器 extends 复合体分析器<默认部件分析, 默认复合体分析> {
  static readonly type = "默认";
  private 全部结构符元素: Set<结构符元素>;

  constructor(x: 字形分析配置) {
    super(x);
    this.全部结构符元素 = new Set(
      [...x.决策.keys(), ...x.决策空间.keys()].filter(
        (y) => y instanceof 结构符元素,
      ),
    );
  }

  分析(复合体: 复合体) {
    const 分析: 默认复合体分析 = {
      类型: "复合体",
      复合体,
      结构: this.全部结构符元素
        .values()
        .find((x) => x.获取名称() === 复合体.结构描述字符)!,
      字根序列: [],
    };
    分析.字根序列.push(...this.顺序取根(复合体));
    return ok(分析);
  }

  动态分析(复合体: 复合体) {
    const 结果列表: 带条件<默认复合体分析>[] = [];
    for (const { 字根序列, 条件列表 } of this.动态顺序取根(复合体)) {
      结果列表.push({
        类型: "复合体",
        复合体,
        字根序列,
        结构: this.全部结构符元素
          .values()
          .find((x) => x.获取名称() === 复合体.结构描述字符)!,
        条件列表,
      });
    }
    return ok(new 优先表(结果列表));
  }
}

class 首末取大复合体分析器 extends 复合体分析器<
  首末取大部件分析,
  默认复合体分析
> {
  static readonly type = "首末取大";
  private 全部结构符元素: Set<结构符元素>;

  constructor(x: 字形分析配置) {
    super(x);
    this.全部结构符元素 = new Set(
      [...x.决策.keys(), ...x.决策空间.keys()].filter(
        (y) => y instanceof 结构符元素,
      ),
    );
  }

  分析(复合体: 复合体) {
    const 分析: 默认复合体分析 = {
      类型: "复合体",
      复合体,
      结构: this.全部结构符元素
        .values()
        .find((x) => x.获取名称() === 复合体.结构描述字符)!,
      字根序列: [],
    };
    const 首末取大结果 = this.首末取大顺序取根(复合体);
    分析.字根序列.push(首末取大结果[0]!, 首末取大结果.at(-1)!);
    return ok(分析);
  }

  // 重写这个方法，考虑到首部件取大优先，末部件倒序取大
  首末取大顺序取根(字形: 字形, 末尾 = true): 字根[] {
    if (是部件(字形)) {
      const 部件分析 = this.查找部件分析结果(字形)!;
      return 末尾 ? 部件分析.逆序取大字根序列 : 部件分析.正序取大字根序列;
    }
    const 字根 = this.配置.复合体字根映射.get(字形);
    if (字根 !== undefined && this.配置.字根决策.has(字根)) return [字根];
    const 排序部分列表 = 字形.按首笔排序部分();
    const 部分结果列表 = 字形.部分列表.map((子字形) => {
      let 部件分析: 首末取大部件分析 | undefined;
      const 当前是末尾 = 排序部分列表.indexOf(子字形) === 排序部分列表.length - 1;
      if (是部件(子字形)) 部件分析 = this.查找部件分析结果(子字形);
      const 下一级末尾 = 当前是末尾 && 末尾;
      const 字根序列 = this.首末取大顺序取根(子字形, 下一级末尾);
      return { 字根序列, 部件分析 };
    });
    const result = this.执行笔顺(部分结果列表, 字形.笔顺);
    return result;
  }
}

class 真码复合体分析器 extends 复合体分析器<默认部件分析> {
  static readonly type = "真码";

  分析(复合体: 复合体) {
    const 分析: 基本复合体分析 = {
      类型: "复合体",
      复合体,
      字根序列: [],
    };
    const 字根 = this.配置.复合体字根映射.get(复合体);
    if (字根 !== undefined) {
      分析.字根序列.push(字根);
    } else {
      if (复合体.结构描述字符 === "⿶") {
        // 下包围结构优先取内部
        for (const 字形 of [...复合体.部分列表].reverse()) {
          分析.字根序列.push(...this.顺序取根(字形));
        }
      } else {
        for (const 字形 of 复合体.部分列表) {
          分析.字根序列.push(...this.顺序取根(字形));
        }
      }
    }
    return ok(分析);
  }
}

class 首右复合体分析器 extends 复合体分析器<默认部件分析> {
  static readonly type = "首右";

  分析(复合体: 复合体) {
    const 分析: 基本复合体分析 = {
      类型: "复合体",
      复合体,
      字根序列: [],
    };
    const 字根 = this.配置.复合体字根映射.get(复合体);
    if (字根 !== undefined && this.配置.字根决策.has(字根)) {
      分析.字根序列.push(字根);
    } else {
      const [第一部, 第二部] = 复合体.按首笔排序部分();
      if (!第一部 || !第二部) return default_err(`${复合体.字符} 缺少部分`);
      const 完整字根序列 = this.顺序取根(复合体);
      const 第一部字根序列 = this.顺序取根(第一部);
      const 第二部字根序列 = this.顺序取根(第二部);
      if (/[⿰⿲]/.test(复合体.结构描述字符)) {
        分析.字根序列 = [第一部字根序列[0]!, 第二部字根序列[0]!];
      } else {
        分析.字根序列 = [完整字根序列[0]!, 完整字根序列.at(-1)!];
      }
    }
    return ok(分析);
  }

  动态分析(复合体: 复合体) {
    const 分析列表: 带条件<基本复合体分析>[] = [];
    const 字根 = this.配置.复合体字根映射.get(复合体);
    if (字根 !== undefined) {
      const 是可选字根 = this.配置.可选字根.has(字根);
      const 条件列表 = 是可选字根 ? [存在(字根)] : [];
      分析列表.push({ 类型: "复合体", 复合体, 字根序列: [字根], 条件列表 });
      if (!是可选字根) return ok(new 优先表(分析列表));
    }
    const [第一部, 第二部] = 复合体.按首笔排序部分();
    if (!第一部 || !第二部) return default_err(`${复合体.字符} 缺少部分`);
    if (/[⿰⿲]/.test(复合体.结构描述字符)) {
      const 第一部结果 = this.动态顺序取根(第一部).map(
        ({ 字根序列, 条件列表 }) => ({ 字根: 字根序列[0]!, 条件列表 }),
      );
      const 第二部结果 = this.动态顺序取根(第二部).map(
        ({ 字根序列, 条件列表 }) => ({ 字根: 字根序列[0]!, 条件列表 }),
      );
      分析列表.push(
        ...贝叶斯推断([第一部结果, 第二部结果] as const, ([x, y]) => ({
          类型: "复合体" as const,
          复合体,
          字根序列: [x.字根, y.字根],
        })),
      );
    } else {
      for (const { 字根序列, 条件列表 } of this.动态顺序取根(复合体)) {
        分析列表.push({
          类型: "复合体",
          复合体,
          字根序列: [字根序列[0]!, 字根序列.at(-1)!],
          条件列表,
        });
      }
    }
    return ok(new 优先表(分析列表));
  }
}

class 二笔复合体分析器 extends 复合体分析器 {
  static readonly type = "二笔";

  取首根(字形: 字形): 字根 {
    if (是部件(字形)) {
      return this.查找部件分析结果(字形)!.字根序列[0]!;
    } else {
      const 字根 = this.配置.复合体字根映射.get(字形);
      if (字根 !== undefined && this.配置.字根决策.has(字根)) return 字根;
      const 第一部 = 字形.按首笔排序部分()[0]!;
      return this.取首根(第一部);
    }
  }

  动态取首根(字形: 字形): 带条件<{ 字根: 字根 }>[] {
    const 结果列表: 带条件<{ 字根: 字根 }>[] = [];
    let 当前字形 = 字形;
    while (!是部件(当前字形)) {
      const 字根 = this.配置.复合体字根映射.get(当前字形);
      if (字根) {
        const 条件列表 = this.配置.可选字根.has(字根) ? [存在(字根)] : [];
        结果列表.push({ 字根, 条件列表 });
        if (!this.配置.可选字根.has(字根)) {
          return 结果列表;
        }
      }
      当前字形 = 当前字形.按首笔排序部分()[0]!;
    }
    const 部件分析 = this.查找动态部件分析结果(当前字形);
    if (!部件分析) return 结果列表;
    结果列表.push(
      ...[...部件分析].map((x) => ({
        条件列表: x.条件列表,
        字根: x.字根序列[0]!,
      })),
    );
    return 结果列表;
  }

  分析(复合体: 复合体) {
    const 分析: 基本复合体分析 = {
      类型: "复合体",
      复合体,
      字根序列: [],
    };
    const 字根 = this.配置.复合体字根映射.get(复合体);
    if (字根 !== undefined && this.配置.字根决策.has(字根)) {
      分析.字根序列.push(字根);
      return ok(分析);
    }
    const 排序部分结果 = 复合体.按首笔排序部分();
    if (排序部分结果.length === 3) {
      for (const 部分 of 排序部分结果) {
        分析.字根序列.push(this.取首根(部分));
      }
    } else {
      const [第一部, 第二部] = 排序部分结果;
      if (!第一部 || !第二部) return default_err(`${复合体.字符} 缺少部分`);
      分析.字根序列.push(this.取首根(第一部));
      if (第二部 instanceof 部件) {
        分析.字根序列.push(...this.查找部件分析结果(第二部)!.字根序列);
      } else {
        const 第二部字根 = this.配置.复合体字根映射.get(第二部);
        if (第二部字根 !== undefined && this.配置.字根决策.has(第二部字根)) {
          分析.字根序列.push(第二部字根);
        } else {
          const [第二部之一, 第二部之二] = 第二部.按首笔排序部分();
          if (!第二部之一 || !第二部之二)
            return default_err(`${复合体.字符} 缺少部分`);
          分析.字根序列.push(this.取首根(第二部之一));
          分析.字根序列.push(this.取首根(第二部之二));
        }
      }
    }
    return ok(分析);
  }

  动态分析(复合体: 复合体) {
    const 分析列表: 带条件<基本复合体分析>[] = [];
    const 字根 = this.配置.复合体字根映射.get(复合体);
    if (字根 !== undefined) {
      const 是可选字根 = this.配置.可选字根.has(字根);
      const 条件列表 = 是可选字根 ? [存在(字根)] : [];
      分析列表.push({ 类型: "复合体", 复合体, 字根序列: [字根], 条件列表 });
      if (!是可选字根) return ok(new 优先表(分析列表));
    }
    const 排序部分结果 = 复合体.按首笔排序部分();
    if (排序部分结果.length === 3) {
      const 部分结果列表 = 排序部分结果.map((x) => this.动态取首根(x));
      分析列表.push(
        ...贝叶斯推断(部分结果列表, (xs) => ({
          类型: "复合体" as const,
          复合体,
          字根序列: xs.map((x) => x.字根),
        })),
      );
    } else {
      const [第一部, 第二部] = 排序部分结果;
      if (!第一部 || !第二部) return default_err(`${复合体.字符} 缺少部分`);
      const 第一部结果 = this.动态取首根(第一部);
      if (第二部 instanceof 部件) {
        const 第二部结果 = this.查找动态部件分析结果(第二部);
        if (第二部结果 === undefined)
          return default_err(`${第二部.字符.获取名称()} 查询不到`);
        分析列表.push(
          ...贝叶斯推断([第一部结果, [...第二部结果]] as const, ([x, y]) => ({
            类型: "复合体" as const,
            复合体,
            字根序列: [x.字根, ...y.字根序列],
          })),
        );
      } else {
        const 第二部合并后结果: 带条件<{ 字根序列: 字根[] }>[] = [];
        const 第二部字根 = this.配置.复合体字根映射.get(第二部);
        let 继续分析 = true;
        if (第二部字根 !== undefined) {
          const 是可选字根 = this.配置.可选字根.has(第二部字根);
          const 条件列表 = 是可选字根 ? [存在(第二部字根)] : [];
          第二部合并后结果.push({ 字根序列: [第二部字根], 条件列表 });
          if (!是可选字根) 继续分析 = false;
        }
        if (继续分析) {
          const [第二部之一, 第二部之二] = 第二部.按首笔排序部分();
          if (!第二部之一 || !第二部之二)
            return default_err(`${复合体.字符} 缺少部分`);
          const 第二部之一结果 = this.动态取首根(第二部之一);
          const 第二部之二结果 = this.动态取首根(第二部之二);
          第二部合并后结果.push(
            ...贝叶斯推断(
              [第二部之一结果, 第二部之二结果] as const,
              ([x, y]) => ({
                字根序列: [x.字根, y.字根],
              }),
            ),
          );
        }
        分析列表.push(
          ...贝叶斯推断([第一部结果, 第二部合并后结果] as const, ([x, y]) => ({
            类型: "复合体" as const,
            复合体,
            字根序列: [x.字根, ...y.字根序列],
          })),
        );
      }
    }
    return ok(new 优先表(分析列表));
  }
}

interface 星空键道复合体分析 extends 基本复合体分析 {
  首部字根序列: 字根[];
  余部字根序列: 字根[];
}

class 星空键道复合体分析器 extends 复合体分析器<
  默认部件分析,
  星空键道复合体分析
> {
  static readonly type = "星空键道";

  分析(复合体: 复合体) {
    const 分析: 星空键道复合体分析 = {
      类型: "复合体",
      复合体,
      字根序列: [],
      首部字根序列: [],
      余部字根序列: [],
    };
    const 字根 = this.配置.复合体字根映射.get(复合体);
    if (字根 !== undefined) {
      分析.字根序列.push(字根);
      return ok(分析);
    }
    分析.字根序列 = this.顺序取根(复合体);
    if (复合体.笔顺[0]?.index === 1) {
      // 第一个书写的部分只写了一笔，视同独体字取码
    } else {
      const 排序部分结果 = 复合体.按首笔排序部分();
      for (const [index, part] of 排序部分结果.entries()) {
        if (index === 0) {
          分析.首部字根序列.push(...this.顺序取根(part));
        } else {
          分析.余部字根序列.push(...this.顺序取根(part));
        }
      }
    }
    return ok(分析);
  }
}

interface 张码复合体分析 extends 基本复合体分析 {
  结构符: 结构描述字符;
  补码: 二笔;
  准码元: 未知元素;
}

class 张码复合体分析器 extends 复合体分析器<张码部件分析, 张码复合体分析> {
  static readonly type = "张码";

  顺序取根(字形: 字形): 字根[] {
    if (是部件(字形)) return this.查找部件分析结果(字形)!.字根序列;
    const 字根 = this.配置.复合体字根映射.get(字形);
    if (字根 !== undefined && this.配置.字根决策.has(字根)) return [字根];
    const 部分结果列表 = 字形.部分列表.map((子字形) => {
      let 字根序列: 字根[];
      if (是部件(子字形)) {
        const 部件分析 = this.查找部件分析结果(子字形);
        字根序列 = 部件分析!.字根序列;
      } else 字根序列 = this.顺序取根(子字形);
      return 字根序列;
    });
    if (字形.结构描述字符 === "⿶") {
      // 下包围结构优先取内部
      return 部分结果列表.reverse().flat();
    } else {
      return 部分结果列表.flat();
    }
  }

  分析(复合体: 复合体) {
    const 分析: 张码复合体分析 = {
      类型: "复合体",
      复合体,
      字根序列: [],
      结构符: 复合体.结构描述字符,
      补码: 二笔.创建(1, 1),
      准码元: new 未知元素("false"),
    };
    const 字根 = this.配置.复合体字根映射.get(复合体);
    if (字根 !== undefined) {
      分析.字根序列.push(字根);
    } else {
      const 展开部分列表 = this.展开嵌套上下和左右结构(复合体);
      if (/[⿱⿳]/.test(复合体.结构描述字符)) {
        分析.字根序列 = this.上下结构取码规则(展开部分列表);
      } else if (/[⿰⿲]/.test(复合体.结构描述字符)) {
        分析.字根序列 = this.左右结构取码规则(展开部分列表);
      } else {
        // 下包围和「竖折」笔画的左下包围优先取内部，其余取外部
        if (
          复合体.结构描述字符 === "⿶" ||
          (复合体.结构描述字符 === "⿺" &&
            复合体.部分列表[0]?.字符?.toNumber() === 0x31d7)
        ) {
          for (const part of [...复合体.部分列表].reverse())
            分析.字根序列.push(...this.顺序取根(part));
        } else {
          for (const part of 复合体.部分列表)
            分析.字根序列.push(...this.顺序取根(part));
        }
      }
    }
    分析.补码 = 计算张码补码(
      分析.字根序列,
      this.配置.分类器,
      复合体.结构描述字符,
    );
    return ok(分析);
  }

  展开嵌套上下和左右结构(复合体: 复合体) {
    if (复合体.部分列表.length !== 2 || !/[⿰⿱]/.test(复合体.结构描述字符))
      return 复合体.部分列表;
    const 展开后: 字形[] = [];
    const regex = 复合体.结构描述字符 === "⿰" ? /[⿰⿲]/ : /[⿱⿳]/;
    for (const 字形 of 复合体.部分列表) {
      if (
        展开后.length < 2 &&
        !是部件(字形) &&
        !this.配置.复合体字根映射.has(字形) &&
        regex.test(字形.结构描述字符)
      ) {
        展开后.push(...字形.部分列表);
      } else {
        展开后.push(字形);
      }
    }
    return 展开后;
  }

  寻找叠眼及其索引(部分列表: 字形[]) {
    // 叠眼不能是部件，不能是字根，必须是左右结构
    const index = 部分列表.findIndex(
      (x) =>
        !是部件(x) &&
        !this.配置.复合体字根映射.has(x) &&
        /[⿰⿲]/.test(x.结构描述字符),
    );
    return [部分列表.at(index) as 复合体 | undefined, index] as const;
  }

  上下结构取码规则(部分列表: 字形[]) {
    const 字根序列: 字根[] = [];
    const [叠眼, 叠眼索引] = this.寻找叠眼及其索引(部分列表);
    const 叠眼以上序列: 字根[] = [];
    let 叠眼展开: 字形[];
    switch (叠眼索引) {
      case -1: // 没有叠眼
        for (const 字形 of 部分列表) 字根序列.push(...this.顺序取根(字形));
        break;
      case 0: // 叠眼在开头
        叠眼展开 = this.展开嵌套上下和左右结构(叠眼!);
        // 先取叠眼各部分的首根
        for (const [index, 部分分析] of 叠眼展开.entries()) {
          if (index >= 2 && index < 叠眼展开.length - 1) continue; // 叠眼只取一二末
          字根序列.push(this.顺序取根(部分分析)[0]!);
        }
        // 然后取剩余部分的首根和末根
        if (部分列表.length > 2) {
          字根序列.push(this.顺序取根(部分列表[1]!)[0]!);
          字根序列.push(this.顺序取根(部分列表.at(-1)!).at(-1)!);
        } else {
          字根序列.push(...this.首末(this.顺序取根(部分列表[1]!)));
        }
        break;
      default: // 叠眼在中间或末尾
        叠眼展开 = this.展开嵌套上下和左右结构(叠眼!);
        // 叠眼以上，最多可顺序取两根
        for (let index = 0; index < 叠眼索引; ++index) {
          叠眼以上序列.push(...this.顺序取根(部分列表[index]!));
        }
        字根序列.push(...叠眼以上序列.slice(0, 2));
        if (叠眼索引 + 1 < 部分列表.length) {
          // 叠眼在中间时：
          // 如果已取两根，则取叠眼首根和叠眼以下的末根
          // 如果只取了一根，则取叠眼第一部分的首根、叠眼最后一部分的首根、叠眼以下的末根
          字根序列.push(this.顺序取根(叠眼展开[0]!).at(0)!);
          if (字根序列.length === 2) {
            字根序列.push(this.顺序取根(叠眼展开.at(-1)!).at(0)!);
          }
          字根序列.push(this.顺序取根(部分列表.at(-1)!).at(-1)!);
        } else {
          // 叠眼在末尾时：按正常顺序取根
          字根序列.push(...this.顺序取根(叠眼!));
        }
    }
    return 字根序列;
  }

  左右结构取码规则(部分列表: 字形[]) {
    const 字根序列: 字根[] = [];
    const 左部 = 部分列表[0]!;
    let 左部是眼叠 = false;
    if (是复合体(左部) && /[⿱⿳]/.test(左部.结构描述字符)) {
      // 左部是叠型
      const 左部展开 = this.展开嵌套上下和左右结构(左部);
      const [叠眼, 叠眼索引] = this.寻找叠眼及其索引(左部展开);
      let 叠眼展开: 字形[];
      switch (叠眼索引) {
        case -1: // 没有叠眼
          break;
        case 0: // 叠眼在开头
          左部是眼叠 = true;
          // 取左部叠眼首部分和末部分的首根
          叠眼展开 = this.展开嵌套上下和左右结构(叠眼!);
          字根序列.push(this.顺序取根(叠眼展开[0]!)[0]!);
          字根序列.push(this.顺序取根(叠眼展开.at(-1)!)[0]!);
          // 取左部剩余部分的末根
          字根序列.push(this.顺序取根(左部展开.at(-1)!).at(-1)!);
          break;
        default: // 叠眼在中间或末尾
          叠眼展开 = this.展开嵌套上下和左右结构(叠眼!);
          左部是眼叠 = true;
          // 取叠眼以上部分的首根
          字根序列.push(this.顺序取根(左部展开[0]!)[0]!);
          // 取叠眼首部分的首根
          字根序列.push(this.顺序取根(叠眼展开[0]!)[0]!);
          // 叠眼在末尾时，取叠眼末部分的末根
          if (叠眼索引 === 左部展开.length - 1)
            字根序列.push(this.顺序取根(叠眼展开.at(-1)!).at(-1)!);
          // 叠眼在中间时，取左部末部分的末根
          else 字根序列.push(this.顺序取根(左部展开.at(-1)!).at(-1)!);
      }
    }
    if (左部是眼叠) {
      // 已经处理完左部，直接取右部末码即可
      字根序列.push(this.顺序取根(部分列表.at(-1)!).at(-1)!);
    } else {
      // 一般情况，左部、中部最多各取首尾两根
      let 余部开始索引 = 1;
      字根序列.push(...this.首末(this.顺序取根(左部)));
      if (部分列表.length > 2) {
        字根序列.push(...this.首末(this.顺序取根(部分列表[1]!)));
        余部开始索引 = 2;
      }
      // 如果左部和中部已经有 4 根，舍弃一根
      if (字根序列.length === 4) 字根序列.pop();
      for (const 部分分析 of 部分列表.slice(余部开始索引)) {
        字根序列.push(...this.顺序取根(部分分析));
      }
    }
    return 字根序列;
  }

  首末(x: 字根[]) {
    return x.length === 1 ? x : [x[0]!, x.at(-1)!];
  }
}

class 逸码复合体分析器 extends 复合体分析器<逸码部件分析> {
  static readonly type = "逸码";

  列举全部部件(复合体: 复合体) {
    const 部件结果列表: 逸码部件分析[] = [];
    for (const 部分 of 复合体.部分列表) {
      if (部分 instanceof 部件) {
        部件结果列表.push(this.查找部件分析结果(部分)!);
      } else {
        const 部分结果 = this.列举全部部件(部分);
        部件结果列表.push(...部分结果);
      }
    }
    return 部件结果列表;
  }

  分析(复合体: 复合体) {
    const 分析: 基本复合体分析 = {
      类型: "复合体",
      复合体,
      字根序列: [],
    };
    const 字根 = this.配置.复合体字根映射.get(复合体);
    if (字根 !== undefined) {
      分析.字根序列.push(字根);
      const 笔画序列 = 字根.获取笔画序列(this.配置.分类器);
      for (const 笔画 of 笔画序列) {
        分析.字根序列.push(二笔.创建(笔画, 0));
      }
      while (分析.字根序列.length < 6) {
        分析.字根序列.push(分析.字根序列.at(-1)!);
      }
      return ok(分析);
    }
    const 部件序列 = this.列举全部部件(复合体);
    const 最后索引 = 部件序列.length - 1;
    for (const [索引, 部分] of 部件序列.entries()) {
      if (分析.字根序列.length === 0) {
        分析.字根序列.push(...部分.余二拆分方式.字根);
        if (索引 === 最后索引) 分析.字根序列.push(...部分.余二拆分方式.补码);
      } else if (分析.字根序列.length === 1) {
        分析.字根序列.push(...部分.余一拆分方式.字根);
        if (索引 === 最后索引) 分析.字根序列.push(...部分.余一拆分方式.补码);
      } else {
        分析.字根序列.push(...部分.笔画拆分方式.字根);
        if (索引 === 最后索引) 分析.字根序列.push(...部分.笔画拆分方式.补码);
      }
    }
    return ok(分析);
  }
}

interface 冰雪飞花复合体分析 extends 基本复合体分析 {
  部首?: 字根;
  余部: 字根[];
}

interface 冰雪飞花部分信息 {
  部分: 字形;
  是单字根: boolean;
  首根: 字根;
}

class 冰雪飞花复合体分析器 extends 复合体分析器<
  冰雪飞花部件分析,
  冰雪飞花复合体分析
> {
  static readonly type = "冰雪飞花";
  static readonly 弱字根列表: string[] = ["又"];
  private 分析器: 冰雪飞花分析器;

  constructor(配置: 字形分析配置) {
    super(配置);
    this.分析器 = 冰雪飞花分析器.创建(配置);
  }

  查找动态部件全集合分析结果(部件: 部件) {
    return (this.查找动态部件分析结果(部件) as any)
      .__magic as 优先表<默认部件分析>;
  }

  是小集合字根(复合体: 复合体) {
    const 字根 = this.配置.复合体字根映射.get(复合体);
    if (字根 !== undefined && this.分析器.当前在小集合(字根)) return 字根;
  }

  取全集合首根和余部(字形: 字形): 冰雪飞花部分信息 {
    let 当前字形 = 字形;
    while (!是部件(当前字形)) {
      const 字根 = this.配置.复合体字根映射.get(当前字形);
      if (字根 !== undefined && this.配置.字根决策.has(字根)) {
        return {
          部分: 字形,
          是单字根: 当前字形 === 字形,
          首根: 字根,
        };
      } else {
        当前字形 = 当前字形.按首笔排序部分()[0]!;
      }
    }
    const 部件分析结果 = this.查找部件分析结果(当前字形);
    if (部件分析结果 === undefined)
      throw new Error(`部件 ${字形.字符} 没有分析结果`);
    return {
      部分: 字形,
      是单字根: 当前字形 === 字形 && 部件分析结果.全集合字根序列.length === 1,
      首根: 部件分析结果.全集合字根序列[0]!,
    };
  }

  取余部(字形列表: 字形[]): 字根[] {
    if (字形列表.length >= 2) {
      const [第一部, 第二部] = 字形列表;
      const 第一部字根 = this.取小集合首根(第一部!);
      const 第二部字根 = this.取小集合首根(第二部!);
      return [第一部字根, 第二部字根];
    } else if (字形列表.length === 1) {
      const 字形 = 字形列表[0]!;
      if (是部件(字形)) {
        const 部件分析结果 = this.查找部件分析结果(字形);
        if (部件分析结果 === undefined)
          throw new Error(`部件 ${字形.字符} 没有分析结果`);
        return 部件分析结果.字根序列.slice(0, 2);
      } else {
        const 字根 = this.是小集合字根(字形);
        if (字根) return [字根];
        return this.取余部(字形.按首笔排序部分());
      }
    } else {
      throw new Error("没有余部");
    }
  }

  取小集合首根(字形: 字形): 字根 {
    let 当前字形 = 字形;
    while (!是部件(当前字形)) {
      const 字根 = this.是小集合字根(当前字形);
      if (字根) return 字根;
      当前字形 = 当前字形.按首笔排序部分()[0]!;
    }
    const 部件分析结果 = this.查找部件分析结果(当前字形);
    if (部件分析结果 === undefined)
      throw new Error(`部件 ${字形.字符} 没有分析结果`);
    return 部件分析结果.字根序列[0]!;
  }

  动态取全集合首根(字形: 字形): 带条件<冰雪飞花部分信息>[] {
    const 主部优先表: 带条件<冰雪飞花部分信息>[] = [];
    let 当前字形 = 字形;
    while (!是部件(当前字形)) {
      const 字根 = this.配置.复合体字根映射.get(当前字形);
      if (字根 !== undefined) {
        const 可选 = this.分析器.可选字根.has(字根);
        主部优先表.push({
          部分: 字形,
          是单字根: 当前字形 === 字形,
          首根: 字根,
          条件列表: 可选 ? [存在(字根)] : [],
        });
        if (!可选) {
          return 主部优先表;
        }
      } else {
        当前字形 = 当前字形.按首笔排序部分()[0]!;
      }
    }
    const 部件分析结果优先表 = this.查找动态部件全集合分析结果(当前字形)!;
    for (const 部件分析结果 of 部件分析结果优先表) {
      主部优先表.push({
        部分: 字形,
        是单字根: 当前字形 === 字形 && 部件分析结果.字根序列.length === 1,
        首根: 部件分析结果.字根序列[0]!,
        条件列表: 部件分析结果.条件列表,
      });
    }
    return 主部优先表;
  }

  动态取余部(字形列表: 字形[]): 带条件<{ 字根列表: 字根[] }>[] {
    if (字形列表.length >= 2) {
      const [第一部, 第二部] = 字形列表;
      const 第一部列表 = this.动态取小集合首根(第一部!);
      const 第二部列表 = this.动态取小集合首根(第二部!);
      return 贝叶斯推断(
        [第一部列表, 第二部列表],
        ([第一部信息, 第二部信息]) => {
          const 字根列表 = [第一部信息!.字根, 第二部信息!.字根];
          return { 字根列表 };
        },
      );
    } else if (字形列表.length === 1) {
      const 字形 = 字形列表[0]!;
      if (是部件(字形)) {
        const 部件分析结果列表 = this.查找动态部件分析结果(字形)!;
        return [...部件分析结果列表].map((部件分析结果) => ({
          字根列表: 部件分析结果.字根序列.slice(0, 2),
          条件列表: 部件分析结果.条件列表,
        }));
      } else {
        const 结果列表: 带条件<{ 字根列表: 字根[] }>[] = [];
        const 字根 = this.配置.复合体字根映射.get(字形);
        if (字根) {
          const 可选 = this.分析器.可选字根与必要一般字根.has(字根);
          结果列表.push({
            字根列表: [字根],
            条件列表: 可选 ? [this.分析器.在小集合(字根)] : [],
          });
          if (!可选) return 结果列表;
        }
        结果列表.push(...this.动态取余部(字形.按首笔排序部分()));
        return 结果列表;
      }
    } else {
      throw new Error("没有余部");
    }
  }

  动态取小集合首根(字形: 字形): 带条件<{ 字根: 字根 }>[] {
    const 结果列表: 带条件<{ 字根: 字根 }>[] = [];
    let 当前字形 = 字形;
    while (!是部件(当前字形)) {
      const 字根 = this.配置.复合体字根映射.get(当前字形);
      if (字根) {
        const 可选 = this.分析器.可选字根与必要一般字根.has(字根);
        结果列表.push({
          字根,
          条件列表: 可选 ? [this.分析器.在小集合(字根)] : [],
        });
        if (!可选) return 结果列表;
      }
      当前字形 = 当前字形.按首笔排序部分()[0]!;
    }
    const 部件分析结果列表 = this.查找动态部件分析结果(当前字形)!;
    if (部件分析结果列表 === undefined)
      throw new Error(`部件 ${字形.字符} 没有分析结果`);
    for (const 部件分析结果 of 部件分析结果列表) {
      结果列表.push({
        字根: 部件分析结果.字根序列[0]!,
        条件列表: 部件分析结果.条件列表,
      });
    }
    return 结果列表;
  }

  组合逻辑(
    复合体: 复合体,
    首部信息: 冰雪飞花部分信息,
    末部信息: 冰雪飞花部分信息,
  ) {
    let 部首取法: "首" | "末";
    const 是包围结构 = /[⿴⿵⿶⿷⿸⿹⿺⿼⿽⿻]/.test(复合体.结构描述字符);
    const 是准包围结构 = [0x1].includes(首部信息.部分.字符.toNumber());
    // 包围结构二择一：外部是字根就一定取外部，不是就一定取内部
    if (是包围结构 || 是准包围结构) {
      let 外部信息: 冰雪飞花部分信息;
      let 外部: "首" | "末", 内部: "首" | "末";
      if (复合体.部分列表[0] === 首部信息.部分) {
        外部信息 = 首部信息;
        外部 = "首";
        内部 = "末";
      } else {
        外部信息 = 末部信息;
        外部 = "末";
        内部 = "首";
      }
      if (外部信息.是单字根) 部首取法 = 外部;
      else 部首取法 = 内部;
    } else {
      if (首部信息.是单字根 && 末部信息.是单字根) {
        const 特取字 =
          "刈划刖列刘刮劝功孜对忌悲戏戕改攻敉敌敲斐斧欢欣欲歆汞畋瞽紊翔翡翮致蜚裴观贡败赦辈邓邛邝邯邺郅郝难雀雉靓项顺须顼颀颇飒鸡鸹鹆鹘";
        部首取法 = 特取字.includes(复合体.字符.获取名称()) ? "末" : "首";
      } else if (首部信息.是单字根) {
        部首取法 = "首";
      } else if (末部信息.是单字根) {
        部首取法 = "末";
      } else {
        部首取法 = "首";
      }
    }
    return 部首取法;
  }

  分析(复合体: 复合体) {
    const 分析: 冰雪飞花复合体分析 = {
      类型: "复合体",
      复合体,
      字根序列: [],
      余部: [],
    };
    const 字根 = this.是小集合字根(复合体);
    if (字根 !== undefined) {
      分析.余部.push(字根);
    } else {
      const 按首笔排序列表 = 复合体.按首笔排序部分();
      const 首部 = 按首笔排序列表[0]!;
      const 末部 = 按首笔排序列表.at(-1)!;
      const 首部信息 = this.取全集合首根和余部(首部);
      const 末部信息 = this.取全集合首根和余部(末部);
      const 取法 = this.组合逻辑(复合体, 首部信息, 末部信息);
      let 部首: 字根, 余部: 字根[];
      if (取法 === "首") {
        部首 = 首部信息.首根;
        余部 = this.取余部(按首笔排序列表.slice(1));
      } else {
        部首 = 末部信息.首根;
        余部 = this.取余部(按首笔排序列表.slice(0, -1));
      }
      分析.部首 = 部首;
      分析.余部.push(...余部);
    }
    if (分析.部首) 分析.字根序列.push(分析.部首);
    分析.字根序列.push(...分析.余部);
    return ok(分析);
  }

  动态分析(复合体: 复合体) {
    const 分析列表: 带条件<冰雪飞花复合体分析>[] = [];
    const 字根 = this.配置.复合体字根映射.get(复合体);
    if (字根 !== undefined) {
      const 可选 = this.分析器.可选字根与必要一般字根.has(字根);
      分析列表.push({
        类型: "复合体",
        复合体,
        字根序列: [字根],
        余部: [字根],
        条件列表: 可选 ? [this.分析器.在小集合(字根)] : [],
      });
      if (!可选) return ok(new 优先表(分析列表));
    }
    const 按首笔排序列表 = 复合体.按首笔排序部分();
    const 首部 = 按首笔排序列表[0]!;
    const 末部 = 按首笔排序列表.at(-1)!;
    const 首部信息列表: 带条件<冰雪飞花部分信息>[] =
      this.动态取全集合首根(首部);
    const 末部信息列表: 带条件<冰雪飞花部分信息>[] =
      this.动态取全集合首根(末部);
    for (const 首部信息 of 首部信息列表) {
      for (const 末部信息 of 末部信息列表) {
        const 合并条件列表 = [...首部信息.条件列表, ...末部信息.条件列表];
        const 取法 = this.组合逻辑(复合体, 首部信息, 末部信息);
        let 部首: 字根, 余部: 带条件<{ 字根列表: 字根[] }>[];
        if (取法 === "首") {
          部首 = 首部信息.首根;
          余部 = this.动态取余部(按首笔排序列表.slice(1));
        } else {
          部首 = 末部信息.首根;
          余部 = this.动态取余部(按首笔排序列表.slice(0, -1));
        }
        for (const { 字根列表, 条件列表 } of 余部) {
          const 分析: 带条件<冰雪飞花复合体分析> = {
            类型: "复合体",
            复合体,
            字根序列: [部首, ...字根列表],
            部首,
            余部: 字根列表,
            条件列表: 合并条件列表.concat(条件列表),
          };
          分析列表.push(分析);
        }
      }
    }
    return ok(new 优先表(分析列表));
  }
}

export type { 冰雪飞花复合体分析, 复合体分析器, 星空键道复合体分析 };
export {
  二笔复合体分析器,
  冰雪飞花复合体分析器,
  复合体,
  张码复合体分析器,
  星空键道复合体分析器,
  真码复合体分析器,
  逸码复合体分析器,
  首右复合体分析器,
  首末取大复合体分析器,
  默认复合体分析器,
};

import type { 笔画名称 } from "./classifier.js";
import type { 原始汉字数据, 字形描述, 结构描述字符 } from "./data.js";
import type { 取码对象 } from "./element.js";
import type { 源标签 } from "./utils.js";

// config.info begin
export interface 基本信息 {
  name?: string;
  author?: string;
  version?: string;
  description?: string;
}
// config.info end

// config.data begin

export const 字集指示列表 = [
  "minimal",
  "gb2312",
  "general",
  "basic",
  "extended",
  "supplement",
  "panlingual",
  "maximal",
] as const;
export type 字集指示 = (typeof 字集指示列表)[number];

export interface 数据配置 {
  character_set?: 字集指示;
  repertoire?: Record<string, 原始汉字数据>;
  glyph_customization?: 兼容字形自定义;
  transformers?: 变换器[];
  glyph_sources?: 源标签[];
}

export type 兼容字形自定义 = Record<string, 字形描述 | 字形描述[]>;

export type 字形自定义 = Record<string, 字形描述[]>;

export interface 变换器 {
  from: 模式;
  to: 模式;
}

export interface 模式 {
  operator: 结构描述字符;
  operandList: 节点[];
}

export type 节点 = 模式 | 结构变量 | string;

export interface 结构变量 {
  id: number;
}

// config.data end

// config.analysis begin
export interface 分析配置 {
  classifier?: Record<笔画名称, number>;
  degenerator?: 退化配置;
  selector?: string[];
  customize?: Record<string, string[]>;
  dynamic_customize?: Record<string, string[][]>;
  strong?: string[];
  weak?: string[];
  component_analyzer?: string;
  compound_analyzer?: string;
  dynamic?: boolean;
}

export interface 退化配置 {
  feature?: Record<笔画名称, 笔画名称>;
  no_cross?: boolean;
}
// config.analysis end

// config.algebra begin
export type 拼写运算 = 运算规则[];

export type 运算规则 = 变换 | 转写;

interface 变换 {
  type: "xform";
  from: string;
  to: string;
}

interface 转写 {
  type: "xlit";
  from: string;
  to: string;
}
// config.algebra end

// config.form begin
export interface 键盘配置 {
  alphabet?: string;
  mapping_type?: number;
  mapping: 决策;
  mapping_space?: 决策空间;
  mapping_variables?: Record<string, 变量规则>;
  mapping_generators?: 决策生成器规则[];
}

export interface 变量规则 {
  keys: string[];
}

export interface 决策生成器规则 {
  regex: string;
  value: 安排描述;
}

export type 元素位 = { element: string; index: number };

export type 元素位或编码 = string | 元素位;

export type 安排 = null | string | 元素位或编码[] | { element: string };

export type 非空安排 = Exclude<安排, null>;

export type 变量安排 = { variable: string };

export type 广义码位 = 元素位或编码 | 变量安排 | null;

export function 是变量(key: 广义码位): key is 变量安排 {
  return typeof key === "object" && key !== null && "variable" in key;
}

export type 广义安排 = null | string | 广义码位[] | { element: string };

export type 非空广义安排 = Exclude<广义安排, null>;

export function 是归并(value: 广义安排): value is { element: string } {
  return typeof value === "object" && value !== null && "element" in value;
}

export type 决策 = Record<string, 非空安排>;

export type 条件 = { element: string; op: "是" | "不是"; value: 安排 };

export interface 安排描述 {
  value: 广义安排;
  score: number;
  condition?: 条件[];
}

export type 决策空间 = Record<string, 安排描述[]>;
// config.form end

// config.encoder begin

export interface 优先简码 {
  word: string;
  sources: string[][];
  level: number;
}

export interface 编码配置 {
  max_length: number;
  select_keys?: string[];
  auto_select_length?: number;
  auto_select_pattern?: string;
  // 一字词全码
  sources: Record<string, 源节点配置>;
  conditions: Record<string, 条件节点配置>;
  // 多字词全码
  rules?: 构词规则[];
  // 简码
  short_code?: 简码规则[];
  short_code_list?: 优先简码[];
  // 组装器
  assembler?: string;
}

export interface 源节点配置 {
  // 起始节点不应该有一个可编码对象，所以是 null；其他情况都有值
  object: 取码对象 | null;
  // 如果只取其中几码就有值，否则为 undefined
  index?: number;
  // next 是对下个节点的引用，所以是 null
  next: string | null;
  // 节点备注
  notes?: string;
}

export const 二元运算符列表 = [
  "是",
  "不是",
  "匹配",
  "不匹配",
  "编码匹配",
  "编码不匹配",
] as const;
export const 一元运算符列表 = ["存在", "不存在"] as const;
export const 运算符列表 = (一元运算符列表 as readonly 运算符[]).concat(
  ...二元运算符列表,
);
export type 一元运算符 = (typeof 一元运算符列表)[number];
export type 二元运算符 = (typeof 二元运算符列表)[number];
export type 运算符 = 一元运算符 | 二元运算符;

export interface 一元条件配置 {
  object: 取码对象;
  operator: 一元运算符;
  positive: string | null;
  negative: string | null;
  notes?: string;
}

export interface 二元条件配置 {
  object: 取码对象;
  operator: 二元运算符;
  value: string;
  positive: string | null;
  negative: string | null;
  notes?: string;
}

export type 条件节点配置 = 一元条件配置 | 二元条件配置;

type 长度限定 =
  | { length_equal: number }
  | { length_in_range: [number, number] };

export const 多字词长度列表 = [...Array(9).keys()].map((x) => ({
  label: x + 1,
  value: x + 1,
}));

export type 构词规则 = { formula: string } & 长度限定;

export type 简码规则 = { schemes: 简码模式[] } & 长度限定;

export interface 简码模式 {
  prefix: number;
  count?: number;
  select_keys?: string[];
}
// config.encoder end

// config.optimization begin
export interface 码长权重 {
  length: number;
  frequency: number;
}

export type 指法权重 = (number | null)[];

export interface 层级权重 {
  top?: number;
  duplication?: number;
  duplication_squared?: number;
  levels?: 码长权重[];
  fingering?: 指法权重;
}

export const 指法标签列表 = [
  "同手",
  "大跨",
  "小跨",
  "干扰",
  "错手",
  "三连",
  "备用",
  "备用",
];

export interface 部分权重 {
  tiers?: 层级权重[];
  duplication?: number;
  key_distribution?: number;
  pair_equivalence?: number;
  fingering?: 指法权重;
  levels?: 码长权重[];
}

export interface 目标配置 {
  characters_full?: 部分权重;
  characters_short?: 部分权重;
  words_full?: 部分权重;
  words_short?: 部分权重;
  regularization_strength?: number;
}

export type 部分目标类型 = Exclude<keyof 目标配置, "regularization_strength">;

export interface 优化配置 {
  objective: 目标配置;
  metaheuristic: 求解器配置;
}

export const 默认优化配置: 优化配置 = {
  objective: {},
  metaheuristic: {
    algorithm: "SimulatedAnnealing",
  },
};

export interface 求解器配置 {
  algorithm: "SimulatedAnnealing";
  parameters?: {
    t_max: number;
    t_min: number;
    steps: number;
  };
  report_after?: number;
  search_method?: {
    random_move: number;
    random_swap: number;
    random_full_key_swap: number;
  };
  update_interval?: number;
}
// config.optimization end

// config.diagram begin

export type 区块配置 = {
  style?: string;
} & (
  | {
      type: "key" | "uppercase";
    }
  | {
      type: "element";
      match?: string;
    }
  | {
      type: "custom";
      mapping?: string;
    }
);

export interface 图示配置 {
  layout: {
    keys: string[];
  }[];
  contents: 区块配置[];
  row_style?: string;
  cell_style?: string;
}

// config.diagram end

export interface 配置 {
  version?: string;
  // 有值表示它是从示例创建的，无值表示它是从模板创建的
  source: string | null;
  info?: 基本信息;
  data?: 数据配置;
  analysis?: 分析配置;
  algebra?: Record<string, 拼写运算>;
  form: 键盘配置;
  encoder: 编码配置;
  optimization?: 优化配置;
  diagram?: 图示配置;
}

export type 示例配置 = Required<配置>;

export interface 生成配置 extends 配置 {
  generated_mapping_space: 决策空间;
}

import type { 笔画名称 } from "./classifier.js";
import type { 源标签集合 } from "./utils.js";

export type N1 = [number];
export type N2 = [number, number];
export type N3 = [number, number, number];
export type N6 = [number, number, number, number, number, number];

/**
 * 一条 SVG 路径命令
 * h, v, c 的含义参见 SVG 规范
 * z 和 c 的含义相同，但是只用于表示平撇、平点、平捺，这是为了区分
 */
export type 绘制 =
  | {
      command: "h" | "v";
      parameterList: N1;
    }
  | {
      command: "c" | "z";
      parameterList: N6;
    }
  | { command: "a"; parameterList: N1 };

export type 向量 = N2;

/**
 * SVG 笔画
 * feature: 笔画的种类
 * start: 笔画的起点
 * curveList: 笔画的命令列表
 */
export interface 矢量笔画数据 {
  feature: 笔画名称;
  start: 向量;
  curveList: 绘制[];
}

/**
 * 引用笔画
 * index: 源字中笔画的索引
 */
export interface 引用笔画数据 {
  feature: "reference";
  index: number;
}

/**
 * SVG 字形是一系列 SVG 笔画的列表
 */
export type 矢量图形数据 = 矢量笔画数据[];

/**
 * 广义的笔画，包括 SVG 笔画和引用笔画
 */
export type 笔画数据 = 矢量笔画数据 | 引用笔画数据;

/**
 * 基本部件 BasicComponent
 * tags: 部件的标签
 * strokes: 部件包含的 SVG 笔画
 */
export interface 基本部件数据 {
  type: "basic_component";
  tags?: string[];
  strokes: 矢量笔画数据[];
}

/**
 * 派生部件 DerivedComponent
 * tags: 部件的标签
 * source: 部件的源字
 * strokes: 部件包含的 SVG 笔画或引用笔画
 *
 * 引用的笔画的内容需要在渲染时从源字中获取
 */
export interface 衍生部件数据 {
  type: "derived_component";
  tags?: string[];
  source: string;
  strokes: 笔画数据[];
}

/**
 * 拼接部件 SplicedComponent
 * 与复合体相同，但作为部件使用
 */
export interface 拼接部件数据 extends Omit<复合体数据, "type"> {
  type: "spliced_component";
}

export const 结构描述字符列表 = [
  "⿰",
  "⿱",
  "⿲",
  "⿳",
  "⿴",
  "⿵",
  "⿶",
  "⿷",
  "⿸",
  "⿹",
  "⿺",
  "⿻",
  "⿼",
  "⿽",
  "⿾",
  "⿿",
] as const;

/**
 * 结构描述字符
 * 例如 ⿰、⿱ 等
 * 符合 Unicode 中的 Ideography Description Characters
 * 参见 https://en.wikipedia.org/wiki/Ideographic_Description_Characters_(Unicode_block)
 */
export type 结构描述字符 = (typeof 结构描述字符列表)[number];

/**
 * 笔画块
 * index: 部分的索引
 * strokes: 笔画块包含的笔画数，0 表示该笔画块包含所有剩余的笔画
 */
export interface 笔画块 {
  index: number;
  strokes: number;
}

/**
 * 复合体的参数
 * gap2: 第二部分复合体和之前的间距
 * scale2: 第二部分复合体的缩放比例
 * gap3: 第三部分复合体和之前的间距
 * scale3: 第三部分复合体的缩放比例
 */
export interface 复合体参数 {
  gap2?: number;
  scale2?: number;
  gap3?: number;
  scale3?: number;
}

/**
 * 复合体 Compound
 * operator: 结构描述字符
 * operandList: 部分列表，有可能是两部分，也可能是三部分（对于 ⿲、⿳）
 * tags: 复合体的标签
 * order: 笔画块的顺序
 */
export interface 复合体数据 {
  type: "compound";
  tags?: string[];
  operator: 结构描述字符;
  operandList: string[];
  order?: 笔画块[];
  parameters?: 复合体参数;
}

/**
 * 全等 Identity
 * source: 全等的源字
 * tags: 全等的标签
 */
export interface 全等数据 {
  type: "identity";
  tags?: string[];
  source: string;
}

/**
 * 一个字形可以是复合体、部件或全等
 */
export type 字形描述 =
  | 基本部件数据
  | 衍生部件数据
  | 拼接部件数据
  | 复合体数据
  | 全等数据;

export type 带标签<T> = Omit<T, "tags"> & { tags: 源标签集合; compat: boolean };

export type 标签字形描述 =
  | 带标签<基本部件数据>
  | 带标签<衍生部件数据>
  | 带标签<拼接部件数据>
  | 带标签<复合体数据>
  | 带标签<全等数据>;

/**
 * 原始字符 PrimitiveCharacter
 * unicode: 字符的 Unicode 编码
 * tygf: 字符在通用规范汉字集中的类型，0 为不存在，1 为一级字，2 为二级字，3 为三级字
 * gb2312: 字符在 GB2312 中的类型，0 为不存在，1 为一级字，2 为二级字
 * name: 字符的别名（当字符是 PUA 时，这个别名会用来在界面上渲染）
 * gf0014_id: 字符在 GF0014-2009 中的编号
 * gf3001_id: 字符在 GF3001-1997 中的编号
 * glyphs: 字符的字形列表，其中每一个有可能是基本部件、派生部件或复合体
 * ambiguous: 字符是否有分部歧义
 */
export interface 原始汉字数据 {
  unicode: number;
  tygf: 0 | 1 | 2 | 3;
  gb2312: 0 | 1 | 2;
  name: string | null;
  gf0014_id: number | null;
  gf3001_id: number | null;
  glyphs: 字形描述[];
  ambiguous: boolean;
}

export type 原始字库数据 = Record<string, 原始汉字数据>;

import type { 默认汉字分析 } from "./assembly.js";
import type { 分类器 } from "./classifier.js";
import { 部件 } from "./component.js";
import type { 条件节点配置, 源节点配置, 运算符 } from "./config.js";
import type { 结构描述字符 } from "./data.js";
import type { 字根 } from "./repertoire.js";
import type { 字符 } from "./unicode.js";
import {
  type 强类型元素位或编码,
  type 强类型决策,
  type 强类型决策空间,
  计算当前或潜在长度,
} from "./utils.js";

export type 元素 =
  | 字符
  | 笔画
  | 二笔
  | 结构符元素
  | 拼音元素
  | 自定义元素
  | 未知元素;

export class 结构符元素 {
  constructor(private operator: 结构描述字符) {}

  获取名称() {
    return this.operator;
  }
}

export class 拼音元素 {
  constructor(
    public 类型: string,
    public 元素: string,
  ) {}

  获取名称() {
    return `${this.类型}-${this.元素}`;
  }
}

export class 自定义元素 {
  constructor(
    public 类型: string,
    public 元素: string,
  ) {}

  获取名称() {
    return `${this.类型}-${this.元素}`;
  }
}

export class 未知元素 {
  constructor(private 元素: string) {}

  获取名称() {
    return this.元素;
  }
}

export class 笔画 {
  static pool: Map<number, 笔画> = new Map();
  static 创建(笔画类别: number) {
    if (!笔画.pool.has(笔画类别)) {
      笔画.pool.set(笔画类别, new 笔画(笔画类别));
    }
    return 笔画.pool.get(笔画类别)!;
  }
  private constructor(private 笔画类别: number) {}
  获取名称() {
    return this.笔画类别.toString();
  }
  获取笔画序列() {
    return [this.笔画类别];
  }
}

export class 二笔 {
  static pool: Map<string, 二笔> = new Map();
  static 创建(笔画类别1: number, 笔画类别2: number) {
    const key = `${笔画类别1}${笔画类别2}`;
    if (!二笔.pool.has(key)) {
      二笔.pool.set(key, new 二笔(笔画类别1, 笔画类别2));
    }
    return 二笔.pool.get(key)!;
  }
  private constructor(
    private 笔画类别1: number,
    private 笔画类别2: number,
  ) {}
  获取名称() {
    return `${this.笔画类别1}${this.笔画类别2}`;
  }
  获取笔画序列() {
    return [this.笔画类别1, this.笔画类别2];
  }
}

interface 基本 {
  type: string;
}

interface 汉字自身 extends 基本 {
  type: "汉字";
}

interface 固定取码 extends 基本 {
  type: "固定";
  key: string;
}

interface 字音取码 extends 基本 {
  type: "字音";
  subtype: string;
}

interface 字根取码 extends 基本 {
  type: "字根";
  rootIndex: number;
}

interface 字根笔画取码 extends 基本 {
  type: "笔画";
  rootIndex: number;
  strokeIndex: number;
}

interface 字根二笔取码 extends 基本 {
  type: "二笔";
  rootIndex: number;
  strokeIndex: number;
}

interface 结构取码 extends 基本 {
  type: "结构";
}

interface 自定义取码 extends 基本 {
  type: "自定义";
  subtype: string;
  rootIndex: number;
}

interface 特殊取码 extends 基本 {
  type: "特殊";
  subtype: string;
}

export type 取码对象 =
  | 汉字自身
  | 固定取码
  | 字音取码
  | 字根取码
  | 字根笔画取码
  | 字根二笔取码
  | 结构取码
  | 自定义取码
  | 特殊取码;

export const 摘要 = (object: 取码对象) => {
  switch (object.type) {
    case "汉字":
    case "结构":
      return object.type;
    case "固定":
      return object.key;
    case "字音":
      return object.subtype;
    case "字根":
      return `根 ${object.rootIndex}`;
    case "笔画":
      return `根 ${object.rootIndex} 笔 ${object.strokeIndex}`;
    case "二笔":
      return `根 ${object.rootIndex} 笔 (${
        object.strokeIndex * 2 - Math.sign(object.strokeIndex)
      }, ${object.strokeIndex * 2})`;
    case "自定义":
      return `${object.subtype} ${object.rootIndex}`;
    default:
      return `${object.type} ${object.subtype}`;
  }
};

export const 转列表 = (object: 取码对象): (string | number)[] => {
  const list = [object.type];
  switch (object.type) {
    case "汉字":
    case "结构":
      return list;
    case "固定":
      return [...list, object.key];
    case "字音":
      return [...list, object.subtype];
    case "字根":
      return [...list, object.rootIndex];
    case "笔画":
      return [...list, object.rootIndex, object.strokeIndex];
    case "二笔":
      return [...list, object.rootIndex, object.strokeIndex];
    case "自定义":
      return [...list, object.subtype, object.rootIndex];
    default:
      return [...list, object.subtype];
  }
};

export const 从列表生成 = (value: (string | number)[]): 取码对象 => {
  const type = value[0] as 取码对象["type"];
  switch (type) {
    case "汉字":
    case "结构":
      return { type };
    case "固定":
      return { type, key: value[1] as string };
    case "字音":
      return { type, subtype: value[1] as string };
    case "字根":
      return { type, rootIndex: value[1] as number };
    case "笔画":
      return {
        type,
        rootIndex: value[1] as number,
        strokeIndex: value[2] as number,
      };
    case "二笔":
      return {
        type,
        rootIndex: value[1] as number,
        strokeIndex: value[2] as number,
      };
    case "自定义":
      return {
        type,
        subtype: value[1] as string,
        rootIndex: value[2] as number,
      };
    default:
      return { type, subtype: value[1] as string };
  }
};

function signedIndex<T>(a: T[], i: number): T | undefined {
  return i >= 0 ? a[i - 1] : a[a.length + i];
}

export class 取码器 {
  private 当前或潜在长度: Map<元素, number>;
  private 谓词表: Record<
    运算符,
    (
      target: 元素 | undefined,
      value: string | null,
      totalMapping: Map<元素, string>,
    ) => boolean
  > = {
    是: (t, v) => t?.获取名称() === v,
    不是: (t, v) => t?.获取名称() !== v,
    匹配: (t, v) => t !== undefined && new RegExp(v!, "u").test(t.获取名称()),
    不匹配: (t, v) => t !== undefined && !new RegExp(v!, "u").test(t.获取名称()),
    编码匹配: (t, v, m) => t !== undefined && new RegExp(v!, "u").test(m.get(t)!),
    编码不匹配: (t, v, m) => t !== undefined && !new RegExp(v!, "u").test(m.get(t)!),
    存在: (t) => t !== undefined,
    不存在: (t) => t === undefined,
  };

  constructor(
    决策: 强类型决策,
    决策空间: 强类型决策空间,
    private 线性化决策: Map<元素, string>,
    private sources: Record<string, 源节点配置>,
    private conditions: Record<string, 条件节点配置>,
    private max_length: number,
    private 分类器: 分类器,
  ) {
    const 当前或潜在长度 = 计算当前或潜在长度(决策, 决策空间);
    if (!当前或潜在长度.ok) {
      throw new Error(`键盘映射长度计算失败: ${当前或潜在长度.error}`);
    }
    this.当前或潜在长度 = 当前或潜在长度.value;
  }

  取码(汉字分析: 默认汉字分析) {
    let 节点: string | null = "s0";
    const 码位序列: 强类型元素位或编码[] = [];
    while (节点) {
      if (节点.startsWith("s")) {
        const 源: 源节点配置 = this.sources[节点]!;
        const { object, next, index } = 源;
        if (节点 === "s0") {
          节点 = next;
          continue;
        }
        const 元素 = this.寻找(object!, 汉字分析);
        if (元素 === undefined) {
          // 如果找不到该元素，跳过
        } else if (元素 instanceof 未知元素) {
          // 如果是固定编码，直接加入
          码位序列.push(元素.获取名称());
        } else {
          const 长度 = this.当前或潜在长度.get(元素) ?? 0;
          // 如果没有定义指标，就是全取；否则检查指标是否有效并取
          if (index === undefined) {
            for (let i = 0; i < 长度; i++) {
              码位序列.push({ element: 元素, index: i });
            }
          } else {
            if (index < 长度 && index >= 0) {
              码位序列.push({ element: 元素, index });
            }
          }
        }
        节点 = next;
      } else {
        const 条件: 条件节点配置 = this.conditions[节点]!;
        if (this.满足(条件, 汉字分析)) {
          节点 = 条件.positive;
        } else {
          节点 = 条件.negative;
        }
      }
    }
    return 码位序列.slice(0, this.max_length ?? 码位序列.length);
  }

  寻找(object: 取码对象, result: 默认汉字分析): 元素 | undefined {
    const { 拼写运算, 字根序列 } = result;
    let root: 字根 | undefined;
    let strokes: number[];
    let name: string;
    let stroke1: number | undefined;
    let stroke2: number | undefined;
    let special: 元素 | undefined;
    switch (object.type) {
      case "汉字":
        return result.汉字;
      case "固定":
        return new 未知元素(object.key);
      case "字音":
        name = object.subtype;
        return 拼写运算.get(name);
      case "字根":
        root = signedIndex(字根序列, object.rootIndex);
        if (root === undefined) return undefined;
        return root instanceof 部件 ? root.字符 : root;
      case "笔画":
      case "二笔":
        root = signedIndex(字根序列, object.rootIndex);
        if (root === undefined) return undefined;
        strokes = root.获取笔画序列(this.分类器);
        if (object.type === "笔画") {
          const number = signedIndex(strokes, object.strokeIndex);
          return number ? 笔画.创建(number) : undefined;
        }
        stroke1 = signedIndex(
          strokes,
          object.strokeIndex * 2 - Math.sign(object.strokeIndex),
        );
        if (stroke1 === undefined) return undefined;
        stroke2 = signedIndex(strokes, object.strokeIndex * 2);
        return 二笔.创建(stroke1, stroke2 ?? 0);
      case "结构":
        console.log(result);
        return "结构" in result ? result.结构 : undefined;
      case "自定义":
        return signedIndex(
          result.自定义元素.get(object.subtype) ?? [],
          object.rootIndex,
        );
      default:
        special = (result as any)[object.subtype] as 元素;
        return special;
    }
  }

  /**
   * 给定一个条件，判断是否满足
   *
   * @param condition - 条件
   * @param result - 中间结果
   * @param config - 配置
   * @param extra - 额外信息
   * @param totalMapping - 映射
   */
  满足(condition: 条件节点配置, result: 默认汉字分析) {
    const { object, operator } = condition;
    const target = this.寻找(object, result);
    const fn = this.谓词表[operator];
    if ("value" in condition) {
      return fn(target, condition.value, this.线性化决策);
    }
    return fn(target, null, this.线性化决策);
  }
}

export * from "./main.js";

import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { load } from "js-yaml";
import Pako from "pako";
import { 组装, type 组装配置 } from "./assembly.js";
import { 合并分类器 } from "./classifier.js";
import type { 配置 } from "./config.js";
import type { 原始汉字数据 } from "./data.js";
import type { 元素 } from "./element.js";
import {
  分析拼音,
  合并拼写运算,
  type 拼音分析映射,
  type 拼音分析结果,
} from "./pinyin.js";
import { 原始字库 } from "./primitive.js";
import type { 字库, 字形分析结果 } from "./repertoire.js";
import {
  ok,
  type Result,
  决策图,
  type 原始词典,
  type 强类型决策,
  type 强类型决策空间,
  构建强类型决策与决策空间,
  构建强类型自定义分析,
  标准化自定义,
  type 源标签,
  type 自定义分析,
  type 自定义分析映射,
  解析原始词典,
  解析当量映射,
  解析笔画数据,
  解析键位分布目标,
  计算全部合法元素与元素映射,
  计算拼音分析与元素映射,
  type 词典,
  读取表格,
  type 键位分布目标,
} from "./utils.js";

// ESM 中模拟 __dirname
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

export function 读取配置(路径: string): 配置 {
  const 内容 = readFileSync(路径, "utf-8");
  return load(内容) as 配置;
}

// 辅助函数：从数据文件读取并解析
function 读取数据文件<T>(
  文件名: string,
  解析函数: (tsv: string[][]) => T,
  自定义路径?: string,
): T {
  const 默认路径 = path.join(__dirname, "data", 文件名);
  const 内容 = readFileSync(自定义路径 ?? 默认路径, "utf-8");
  const tsv = 读取表格(内容);
  return 解析函数(tsv);
}

export function 获取原始字库(自定义字库: 原始汉字数据[] = []): 原始字库 {
  const 路径 = path.join(__dirname, "data", "repertoire.json.deflate");
  const 内容 = Pako.inflate(readFileSync(路径), { to: "string" });
  const 原始字库数据: 原始汉字数据[] = JSON.parse(内容);
  return new 原始字库([...原始字库数据, ...自定义字库]);
}

export function 获取原始词典(路径: string | undefined): 原始词典 {
  return 读取数据文件("dictionary.txt", 解析原始词典, 路径);
}

export function 获取键位分布目标(路径?: string): 键位分布目标 {
  return 读取数据文件("distribution.txt", 解析键位分布目标, 路径);
}

export function 获取当量映射(路径?: string) {
  return 读取数据文件("equivalence.txt", 解析当量映射, 路径);
}

export function 获取通用规范汉字笔画数据(路径?: string) {
  return 读取数据文件("tygf.txt", 解析笔画数据, 路径);
}

export function 获取CJK汉字笔画数据(路径?: string) {
  return 读取数据文件("cjk.txt", 解析笔画数据, 路径);
}

export function 获取自定义分析与元素映射(
  自定义元素文件集合: Record<string, string>,
  原始字库: 原始字库,
) {
  const 自定义元素集合: Record<string, 自定义分析> = {};
  for (const [名称, 文件路径] of Object.entries(自定义元素文件集合)) {
    const tsv = 读取表格(readFileSync(文件路径, "utf-8"));
    const 查找表: Record<string, string[]> = {};
    for (const [char, elements] of tsv) {
      if (char === undefined || elements === undefined) continue;
      查找表[char] = elements.split(" ");
    }
    自定义元素集合[名称] = 查找表;
  }
  return 原始字库.校验自定义映射(自定义元素集合);
}

export function 获取拼音分析与元素映射(config: 配置, 词典: 词典) {
  const 拼写运算查找表 = 合并拼写运算(config.algebra);
  return 计算拼音分析与元素映射(词典, 拼写运算查找表);
}

export function 获取字库(配置: 配置): Result<字库, Error> {
  const 用户原始字库数据 = 配置.data?.repertoire ?? {};
  const 原始字库 = 获取原始字库(Object.values(用户原始字库数据));
  const 自定义字形 = 配置.data?.glyph_customization ?? {};
  const 变换器列表 = 配置.data?.transformers ?? [];
  const 字形来源列表 = (配置.data?.glyph_sources ?? []) as 源标签[];
  const 字库或错误 = 原始字库.确定(
    标准化自定义(自定义字形),
    变换器列表,
    字形来源列表,
  );
  if (!字库或错误.ok) {
    return 字库或错误;
  }
  return ok(字库或错误.value);
}

export function 获取决策与决策空间(
  配置: 配置,
  字库: 字库,
  词典: 词典,
  原始字库: 原始字库,
) {
  const 分类器 = 合并分类器(配置.analysis?.classifier);
  const { 拼音元素映射 } = 获取拼音分析与元素映射(配置, 词典);
  const { 自定义元素映射 } = 获取自定义分析与元素映射({}, 原始字库);
  const 字符列表 = [...字库].map(({ 字符 }) => 字符);
  const { 名称映射 } = 计算全部合法元素与元素映射(
    字符列表,
    分类器,
    拼音元素映射,
    自定义元素映射,
  );
  return 构建强类型决策与决策空间(
    配置.form.mapping,
    配置.form.mapping_space ?? {},
    名称映射,
  );
}

export function 获取字形分析结果(
  配置: 配置,
  字库: 字库,
  词典: 词典,
  名称映射: Map<string, 元素>,
  原始字库: 原始字库,
) {
  const { 决策, 决策空间 } = 获取决策与决策空间(配置, 字库, 词典, 原始字库);
  const 如线性化决策 = new 决策图(决策).线性化();
  if (!如线性化决策.ok) throw 如线性化决策.error;
  const 线性化决策 = 如线性化决策.value;
  const { 自定义分析映射, 动态自定义分析映射 } = 构建强类型自定义分析(
    字库,
    原始字库,
    名称映射,
    配置.analysis?.customize ?? {},
    配置.analysis?.dynamic_customize ?? {},
  );
  const 字形分析配置 = {
    决策,
    决策空间,
    自定义分析映射,
    动态自定义分析映射,
    分析配置: 配置.analysis ?? {},
    字形来源列表: 配置.data?.glyph_sources ?? [],
    线性化决策,
  };
  const 汉字集合 = 原始字库.获取汉字集合(词典);
  return 字库.分析(字形分析配置, 汉字集合);
}

export function 获取拼音分析结果(拼音分析映射: 拼音分析映射, 词典: 词典) {
  return 分析拼音(拼音分析映射, 词典);
}

export function 获取组装结果(
  配置: 配置,
  决策: 强类型决策,
  决策空间: 强类型决策空间,
  线性化决策: Map<元素, string>,
  拼音分析结果: 拼音分析结果,
  字形分析结果: 字形分析结果,
  自定义分析结果: 自定义分析映射 = new Map(),
) {
  const 组装配置: 组装配置 = {
    决策,
    决策空间,
    线性化决策,
    最大码长: 配置.encoder.max_length,
    源映射: 配置.encoder.sources,
    条件映射: 配置.encoder.conditions,
    构词规则列表: 配置.encoder.rules ?? [],
    组装器: 配置.encoder.assembler,
    键盘配置: 配置.form,
    自定义分析映射: 自定义分析结果,
    分类器: 合并分类器(配置.analysis?.classifier),
  };
  const res = 组装(组装配置, 拼音分析结果, 字形分析结果);
  return res;
}

import { 星空键道组装器, 默认组装器 } from "./assembly.js";
import {
  二笔部件分析器,
  冰雪飞花部件分析器,
  张码部件分析器,
  逸码部件分析器,
  首末取大部件分析器,
  默认部件分析器,
} from "./component.js";
import {
  二笔复合体分析器,
  冰雪飞花复合体分析器,
  张码复合体分析器,
  星空键道复合体分析器,
  真码复合体分析器,
  逸码复合体分析器,
  首右复合体分析器,
  首末取大复合体分析器,
  默认复合体分析器,
} from "./compound.js";
import { 默认拼音分析器 } from "./pinyin.js";
import { type 注册表, 获取注册表 } from "./registry.js";
import {
  倒序取大,
  全符笔顺,
  取大优先,
  取小优先,
  同向笔画,
  多强字根,
  少弱字根,
  根少优先,
  结构完整,
  能散不连,
  能连不交,
  连续笔顺,
  非形近根,
  首末取大,
} from "./selector.js";

export * from "./affine.js";
export * from "./assembly.js";
export * from "./bezier.js";
export * from "./classifier.js";
export * from "./component.js";
export * from "./compound.js";
export * from "./config.js";
export * from "./data.js";
export * from "./element.js";
export * from "./math.js";
export * from "./pinyin.js";
export * from "./primitive.js";
export * from "./registry.js";
export * from "./repertoire.js";
export * from "./selector.js";
export * from "./unicode.js";
export * from "./utils.js";

export function 注册内置组件(registry: 注册表) {
  for (const x of [
    默认部件分析器,
    二笔部件分析器,
    张码部件分析器,
    逸码部件分析器,
    冰雪飞花部件分析器,
    // 首末取大部件分析器,
  ])
    registry.注册部件分析器(x);
  for (const x of [
    默认复合体分析器,
    二笔复合体分析器,
    张码复合体分析器,
    逸码复合体分析器,
    真码复合体分析器,
    星空键道复合体分析器,
    首右复合体分析器,
    冰雪飞花复合体分析器,
    // 首末取大复合体分析器,
  ])
    registry.注册复合体分析器(x);
  for (const x of [默认组装器, 星空键道组装器]) registry.注册组装器(x);
  for (const x of [默认拼音分析器]) registry.注册拼音分析器(x);
  for (const x of [
    全符笔顺,
    取大优先,
    取小优先,
    倒序取大,
    首末取大,
    同向笔画,
    多强字根,
    少弱字根,
    根少优先,
    结构完整,
    能散不连,
    能连不交,
    连续笔顺,
    非形近根,
  ])
    registry.注册筛选器(x);
  return registry;
}

注册内置组件(获取注册表());

import type { N2 } from "./data.js";

export const 加 = (a: N2, b: N2): N2 => [a[0] + b[0], a[1] + b[1]];

export const 减 = (a: N2, b: N2): N2 => [a[0] - b[0], a[1] - b[1]];

export const 乘 = (a: number, b: N2): N2 => [a * b[0], a * b[1]];

export const 除 = (a: N2, b: number): N2 => [a[0] / b, a[1] / b];

export const 点乘 = (a: N2, b: N2): number => a[0] * b[0] + a[1] * b[1];

export const 叉乘 = (a: N2, b: N2): number => a[0] * b[1] - a[1] * b[0];

export const 距离 = (a: N2, b: N2): number =>
  Math.sqrt((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2);

export const 排序 = (a: number, b: number): N2 => (a < b ? [a, b] : [b, a]);

/**
 * Determine if the point is on a given segment
 * @param from - starting point
 * @param to - end point
 * @param point - another point
 * @returns
 */
export const 是共线 = (from: N2, to: N2, point: N2) => {
  const [u, v] = [减(to, point), 减(from, point)];
  return 叉乘(u, v) === 0 && 点乘(u, v) < 0;
};

/**
 * 比较两个数列的大小
 * @param a - 数列 a
 * @param b - 数列 b
 * @returns 如果 a < b 则返回 true，否则返回 false
 */
export const 是小于 = (a: number[], b: number[]) => {
  for (const [i, v] of a.entries()) {
    const u = b[i];
    if (u === undefined) return false;
    if (v < u) return true;
    if (v > u) return false;
  }
  return false;
};

import type { 拼写运算, 运算规则 } from "./config.js";
import type { 拼音元素 } from "./element.js";
import { 获取注册表 } from "./registry.js";
import type { 字符 } from "./unicode.js";
import {
  default_err,
  ok,
  type Result,
  type 词典,
  type 词典条目,
} from "./utils.js";

const r = String.raw;

const 拼写运算查找表: Record<string, 拼写运算> = {
  声母: [
    { type: "xform", from: "^([bpmfdtnlgkhjqxzcsr]h?|^).+$", to: "$1" },
    { type: "xform", from: "^$", to: "0" },
  ],
  韵母: [
    // 恢复 v
    { type: "xform", from: "^([jqxy])u", to: "$1v" },
    // 恢复合、齐、撮口的韵母形式
    { type: "xform", from: "yv", to: "v" },
    { type: "xform", from: "yi?", to: "i" },
    { type: "xform", from: "wu?", to: "u" },
    // 恢复 iou, uei, uen
    { type: "xform", from: "iu", to: "iou" },
    { type: "xform", from: "u([in])", to: "ue$1" },
    { type: "xform", from: r`^.*?([aeêiouv].*|m|ng?)\d$`, to: "$1" },
  ],
  双拼声母: [
    { type: "xform", from: "^([bpmfdtnlgkhjqxzcsryw]h?|^).+$", to: "$1" },
    { type: "xform", from: "^$", to: "0" },
  ],
  双拼韵母: [{ type: "xform", from: r`^.*?([aeêiouv].*|m|ng?)\d$`, to: "$1" }],
  声调: [{ type: "xform", from: r`.+(\d)`, to: "$1" }],
  首字母: [{ type: "xform", from: r`^(.).+`, to: "$1" }],
  末字母: [{ type: "xform", from: r`.*(.)\d`, to: "$1" }],
};

function 合并拼写运算(自定义?: Record<string, 拼写运算>) {
  const 查找表 = new Map<string, 拼写运算>();
  const 合并 = { ...拼写运算查找表, ...(自定义 ?? {}) };
  for (const [名称, 规则列表] of Object.entries(合并)) {
    查找表.set(名称, 规则列表);
  }
  return 查找表;
}

type 拼音元素映射 = Map<string, 拼音元素>;

interface 拼音分析器 {
  分析(词: 字符[], 拼音: string[]): Result<拼音元素映射[], Error>;
}

export function 应用拼写运算(规则列表: 运算规则[], 音节: string) {
  let 结果 = 音节;
  for (const { type, from, to } of 规则列表) {
    switch (type) {
      case "xform":
        结果 = 结果.replace(new RegExp(from, "u"), to);
        break;
      case "xlit":
        结果 = 结果.replace(new RegExp(`[${from}]`, "u"), (s) => {
          const index = from.indexOf(s);
          return to[index] || "";
        });
        break;
    }
  }
  return 结果;
}

class 默认拼音分析器 implements 拼音分析器 {
  static readonly type = "默认";
  constructor(private 拼音分析映射: 拼音分析映射) {}

  分析(_词: 字符[], 拼音: string[]) {
    const 元素映射列表: 拼音元素映射[] = [];
    for (const 音节 of 拼音) {
      const 音节结果 = this.拼音分析映射.get(音节);
      if (!音节结果) return default_err(`未知音节：${音节}`);
      元素映射列表.push(音节结果);
    }
    return ok(元素映射列表);
  }
}

interface 拼音分析 extends 词典条目 {
  元素映射: 拼音元素映射[];
}

type 拼音分析结果 = 拼音分析[];

type 拼音分析映射 = Map<string, Map<string, 拼音元素>>;

function 分析拼音(音节表: 拼音分析映射, 词典: 词典) {
  const 注册表 = 获取注册表();
  const 拼音分析器 = 注册表.创建拼音分析器("默认", 音节表)!;
  const 拼音分析结果: 拼音分析[] = [];
  for (const { 词, 拼音, 频率 } of 词典) {
    const 元素映射 = 拼音分析器.分析(词, 拼音);
    if (!元素映射.ok) continue;
    拼音分析结果.push({ 词, 拼音, 频率, 元素映射: 元素映射.value });
  }

  return 拼音分析结果;
}

export type { 拼音分析, 拼音分析器, 拼音分析映射, 拼音分析结果 };
export { 分析拼音, 合并拼写运算, 拼写运算查找表, 默认拼音分析器 };

import { min } from "lodash-es";
import { 图形盒子 } from "./affine.js";
import { 部件 } from "./component.js";
import { 复合体 } from "./compound.js";
import type { 变换器, 字形自定义, 字集指示, 模式, 节点 } from "./config.js";
import type {
  原始汉字数据,
  复合体数据,
  字形描述,
  标签字形描述,
  矢量图形数据,
  笔画块,
} from "./data.js";
import { 自定义元素 } from "./element.js";
import { 字库, type 字形 } from "./repertoire.js";
import { 字符, 字集过滤查找表 } from "./unicode.js";
import {
  default_err,
  ok,
  type Result,
  type 原始词典,
  所有源标签,
  排列组合,
  是源标签,
  模拟基本部件,
  type 源标签,
  type 源标签集合,
  type 自定义分析,
  type 自定义分析映射,
  type 词典,
} from "./utils.js";

// 变量映射：variable id -> 字符
type 变量映射 = Map<number, 字符>;

interface 字符与描述列表 {
  字符: 字符;
  描述列表: 标签字形描述[];
}

export interface 校验原始汉字数据 extends 原始汉字数据 {
  character: 字符;
}

class 原始字库 {
  private 字库查找: Map<number, 校验原始汉字数据>;
  constructor(字库: 原始汉字数据[]) {
    this.字库查找 = new Map();
    for (const data of 字库) {
      const 字符实例 = 字符.从码位创建(data.unicode);
      if (!字符实例.ok) continue;
      this.字库查找.set(data.unicode, { ...data, character: 字符实例.value });
    }
  }

  [Symbol.iterator](): Iterator<校验原始汉字数据> {
    return this.字库查找.values();
  }

  查询(字符实例: 字符): 校验原始汉字数据 | undefined {
    return this.字库查找.get(字符实例.toNumber());
  }

  校验(汉字: string): 校验原始汉字数据 | undefined {
    const 字符列表 = [...汉字];
    if (字符列表.length !== 1) return;
    return this.字库查找.get(汉字.codePointAt(0)!);
  }

  /**
   * 将原始字符集转换为字符集
   * 主要的工作是对每个字符，在数据库中的多个字形中选取一个
   *
   * @param 自定义描述 - 自定义字形
   * @param 标签列表 - 用户选择的标签
   *
   * 基本逻辑为，对于每个字符，
   * - 如果用户指定了字形，则使用用户指定的字形
   * - 如果用户指定的某个标签匹配上了这个字符的某个字形，则使用这个字形
   * - 如果都没有，就使用默认字形
   */
  确定(
    自定义描述: 字形自定义,
    变换器列表: 变换器[],
    字形来源列表: 源标签[],
  ): Result<字库, Error> {
    // 0. 将变换器转成用户自定义
    const 用户描述映射 = new Map<字符, 字形描述[]>();
    for (const [字符串, 描述列表] of Object.entries(自定义描述)) {
      const 字符 = this.校验(字符串)?.character;
      if (字符) 用户描述映射.set(字符, [...描述列表]);
    }
    this.应用变换器(用户描述映射, 变换器列表);
    // 1. 合并系统描述列表和用户描述列表
    const 描述列表映射 = new Map<字符, 标签字形描述[]>();
    for (const { character, glyphs } of this.字库查找.values()) {
      const 描述列表: 标签字形描述[] = [];
      const 已有来源 = new Set<源标签>();
      for (const 描述 of 用户描述映射.get(character) ?? []) {
        let 来源集合 = new Set((描述.tags ?? []).filter(是源标签));
        if (来源集合.size === 0) 来源集合 = new Set(所有源标签);
        const 是兼容码 = 已有来源.intersection(来源集合).size > 0;
        描述列表.push({ ...描述, tags: 来源集合, compat: 是兼容码 });
        [...来源集合].map((x) => 已有来源.add(x));
      }
      for (const 描述 of glyphs) {
        let 来源集合 = new Set((描述.tags ?? []).filter(是源标签));
        if (来源集合.size === 0) 来源集合 = new Set(所有源标签);
        const 独立来源集合 = 来源集合.difference(已有来源);
        if (独立来源集合.size > 0) {
          描述列表.push({ ...描述, tags: 独立来源集合, compat: false });
          [...独立来源集合].map((x) => 已有来源.add(x));
        }
      }
      描述列表映射.set(character, 描述列表);
    }
    // 2. 对字符集进行拓扑排序
    const 字符图 = new Map<字符, Set<字符>>();
    const 入度表 = new Map<字符, number>();
    const 无入度: 字符与描述列表[] = [];
    const 拓扑排序汉字: 字符与描述列表[] = [];
    for (const [码位, 字形列表] of 描述列表映射) {
      const 引用的其他字符 = new Set<字符>();
      for (const 字形 of 字形列表) {
        if (字形.type === "compound" || 字形.type === "spliced_component") {
          for (const 字符串 of 字形.operandList) {
            const 字符实例 = this.校验(字符串)?.character;
            if (!字符实例) return default_err(`无法找到字符: ${字符串}`);
            引用的其他字符.add(字符实例);
          }
        } else if (
          字形.type === "derived_component" ||
          字形.type === "identity"
        ) {
          const 字符实例 = this.校验(字形.source)?.character;
          if (!字符实例) return default_err(`无法找到字符: ${字形.source}`);
          引用的其他字符.add(字符实例);
        }
      }
      入度表.set(码位, 引用的其他字符.size);
      if (引用的其他字符.size === 0) {
        无入度.push({ 字符: 码位, 描述列表: 字形列表 });
      } else {
        for (const 其他字符 of 引用的其他字符) {
          if (!字符图.has(其他字符)) 字符图.set(其他字符, new Set());
          字符图.get(其他字符)!.add(码位);
        }
      }
    }
    while (无入度.length) {
      const x = 无入度.shift()!;
      const { 字符 } = x;
      拓扑排序汉字.push(x);
      const 用到该字的字列表 = 字符图.get(字符);
      if (用到该字的字列表 === undefined) continue;
      for (const 字 of 用到该字的字列表) {
        const 字形列表 = 描述列表映射.get(字)!;
        入度表.set(字, 入度表.get(字)! - 1);
        if (入度表.get(字) === 0) {
          无入度.push({ 字符: 字, 描述列表: 字形列表 });
        }
      }
    }
    if (拓扑排序汉字.length !== 描述列表映射.size) {
      const s = new Set(拓扑排序汉字.map((x) => x.字符));
      const missing = [...描述列表映射.keys()].filter((x) => !s.has(x));
      return default_err(
        `存在循环依赖的字符: ${missing.slice(0, 100).map(x => x.获取名称()).join(", ")}，共 ${missing.length} 个`,
      );
    }
    // 3. 将字形数据转化为字形
    const 字库实例 = new 字库();
    for (const { 字符, 描述列表 } of 拓扑排序汉字) {
      const 字形列表: 字形[] = [];
      for (const 描述 of 描述列表) {
        const 字形子列表 = this.渲染字形(字符, 描述, 字库实例);
        if (!字形子列表.ok) return 字形子列表;
        字形列表.push(...字形子列表.value);
      }
      if (字形列表.length === 0) {
        字形列表.push(
          new 部件(
            字符,
            new Set([所有源标签[0]!]),
            false,
            模拟基本部件().strokes,
          ),
        );
      }
      字库实例.添加(字符, 字形列表);
    }
    // 4. 最后根据当前字形来源列表过滤一次
    const 当前来源集合 = new Set(字形来源列表);
    const 过滤后字库 = new 字库();
    for (const { 字符, 字形列表 } of 字库实例) {
      const 过滤后字形列表: 字形[] = [];
      for (const 字形 of 字形列表) {
        const 选取 = 字形.标签集合.intersection(当前来源集合).size > 0;
        if (!选取) continue;
        过滤后字形列表.push(字形);
      }
      if (过滤后字形列表.length === 0) 过滤后字形列表.push(字形列表[0]!);
      let index = 0;
      过滤后字形列表.forEach((x) => {
        if (x instanceof 部件) {
          x.字形序号 = index;
          index += 1;
        }
      });
      过滤后字库.添加(字符, 过滤后字形列表);
    }
    return ok(过滤后字库);
  }

  /**
   * 在数据库上匹配模式到某个键（按需展开并递归调用自身），
   * 变量绑定为子键字符串。
   */
  模式匹配(字形: 字形描述, 模式: 模式, 变量映射: 变量映射): 字形 is 复合体数据 {
    if (字形.type !== "compound") return false;
    if (模式.operator !== 字形.operator) return false;
    if (模式.operandList.length !== 字形.operandList.length) return false;
    for (let i = 0; i < 模式.operandList.length; i++) {
      const 子模式 = 模式.operandList[i]!;
      const 如子部分 = this.校验(字形.operandList[i]!)?.character;
      if (!如子部分) return false;
      const 子部分 = 如子部分;
      if (typeof 子模式 === "string") {
        if (子部分.获取名称() !== 子模式) return false;
      } else if ("id" in 子模式) {
        const id = 子模式.id;
        const 已绑定 = 变量映射.get(id);
        if (已绑定 === undefined) {
          变量映射.set(id, 子部分);
        } else {
          if (已绑定 !== 子部分) return false;
        }
      } else {
        const 子字形列表 = this.字库查找.get(子部分.toNumber())?.glyphs;
        if (!子字形列表) return false;
        const 当前变量映射备份 = structuredClone(变量映射);
        let 至少有一个匹配成功 = false;
        for (const 子字形 of 子字形列表) {
          if (this.模式匹配(子字形, 子模式, 变量映射)) {
            至少有一个匹配成功 = true;
            break;
          }
          变量映射.clear();
          当前变量映射备份.forEach((value, key) => {
            变量映射.set(key, value);
          });
        }
        if (!至少有一个匹配成功) return false;
      }
    }
    return true;
  }

  /**
   * 把 replacement pattern / variable / string 扁平化并写入 dbOut，返回引用该子树的 key。
   * - 模式中的字符串直接视为已有的键引用
   * - 变量使用 varMap 中绑定的键
   * - 嵌套 pattern 递归生成子键
   */
  替换(
    原字形: 复合体数据,
    项: 节点,
    变量映射: 变量映射,
    辅助字符映射: Map<字符, 字形描述[]>,
  ): Result<字形描述 | 字符, Error> {
    if (typeof 项 === "string") {
      const ch = this.校验(项)?.character;
      if (!ch) return default_err(`无法找到字符: ${项}`);
      return ok(ch);
    }
    if ("id" in 项) {
      const 取值 = 变量映射.get(项.id);
      if (!取值) return default_err(`未知的结构变量 ID: ${项.id}`);
      return ok(取值);
    }
    // 当前项是个模式
    const 部分列表: string[] = [];
    for (const 部分 of 项.operandList) {
      const result = this.替换(原字形, 部分, 变量映射, 辅助字符映射);
      if (!result.ok) return result;
      if (result.value instanceof 字符) {
        部分列表.push(result.value.获取名称());
      } else {
        const 如码位 = 字符.获取自由字符();
        if (!如码位.ok) return 如码位;
        辅助字符映射.set(如码位.value, [result.value]);
        部分列表.push(如码位.value.获取名称());
      }
    }
    const 复合体: 复合体数据 = {
      ...原字形,
      operator: 项.operator,
      operandList: 部分列表,
      order: undefined,
    };
    return ok(复合体);
  }

  /**
   * 应用变换器到数据库，返回新的数据库。
   */
  应用变换器(自定义字形映射: Map<字符, 字形描述[]>, 变换器列表: 变换器[]) {
    const 辅助字符映射 = new Map<字符, 字形描述[]>();
    for (const { character, glyphs } of this.字库查找.values()) {
      const 增补列表: 字形描述[] = [];
      for (const 字形 of glyphs) {
        for (const 变换器 of 变换器列表) {
          const 变量映射: 变量映射 = new Map();
          if (this.模式匹配(字形, 变换器.from, 变量映射)) {
            const 新字形 = this.替换(字形, 变换器.to, 变量映射, 辅助字符映射);
            if (!新字形.ok) return 新字形;
            if (新字形.value instanceof 字符)
              return default_err("Unexpected string result");
            增补列表.push(新字形.value);
          }
        }
      }
      if (增补列表.length > 0) {
        const 自定义字形列表 = 自定义字形映射.get(character);
        if (自定义字形列表) 自定义字形列表.push(...增补列表);
        else 自定义字形映射.set(character, 增补列表);
      }
    }
  }

  /**
   * 在字形列表中过滤得到符合该标签的所有字形
   */
  匹配标签(字形列表: 字形[], 标签: 源标签): number[] {
    const 索引列表: number[] = [];
    let 最佳优先级 = Infinity;
    let 备用索引 = -1;
    for (const [索引, 字形] of 字形列表.entries()) {
      const 优先级 = min([...字形.标签集合].map((v) => 所有源标签.indexOf(v)))!;
      if (优先级 < 最佳优先级) {
        备用索引 = 索引;
        最佳优先级 = 优先级;
      }
      if (字形.标签集合.has(标签)) {
        索引列表.push(索引);
      }
    }
    if (索引列表.length === 0) {
      索引列表.push(备用索引);
    }
    return 索引列表;
  }

  /**
   * 递归渲染一个部件（基本部件或者衍生部件）
   * 如果是基本部件就直接返回，如果是衍生部件则先渲染源字的图形，然后解引用得到这个部件的图形
   *
   * @param component - 部件
   * @param repertoire - 原始字符集
   * @param 字形缓存 - 部件缓存
   *
   * @returns 部件的 SVG 图形
   */
  渲染字形(
    字符实例: 字符,
    字形数据: 标签字形描述,
    字库: 字库,
  ): Result<字形[], Error> {
    if (字形数据.type === "basic_component") {
      return ok([
        new 部件(字符实例, 字形数据.tags, 字形数据.compat, 字形数据.strokes),
      ]);
    } else if (
      字形数据.type === "identity" ||
      字形数据.type === "derived_component"
    ) {
      const 源字符 = this.校验(字形数据.source)?.character;
      if (!源字符) return default_err(`无法找到字符: ${字形数据.source}`);
      const 引用字形列表 = 字库.查询字形(源字符);
      if (引用字形列表 === undefined)
        return default_err(`源部件 ${源字符.十六进制()} 不存在`);
      const 字形列表: 字形[] = [];
      const 反向映射: Map<number, 源标签集合> = new Map();
      for (const 标签 of 字形数据.tags) {
        const 过滤后字形列表 = this.匹配标签(引用字形列表, 标签);
        for (const 索引 of 过滤后字形列表) {
          if (!反向映射.has(索引)) 反向映射.set(索引, new Set([标签]));
          else 反向映射.get(索引)!.add(标签);
        }
      }
      // 重新构造
      for (const [索引, 标签集合] of 反向映射) {
        const 字形 = 引用字形列表[索引]!;
        if (字形数据.type === "identity") {
          if (字形 instanceof 部件) {
            字形列表.push(
              new 部件(字符实例, 标签集合, 字形数据.compat, 字形.矢量图形),
            );
          } else {
            字形列表.push(
              new 复合体(
                字符实例,
                标签集合,
                字形数据.compat,
                字形.结构描述字符,
                字形.部分列表,
                字形.笔顺,
              ),
            );
          }
        } else {
          let 引用矢量图形: 矢量图形数据;
          if (字形 instanceof 部件) {
            引用矢量图形 = 字形.矢量图形;
          } else {
            const 图形盒子实例 = 字库.递归渲染复合体(字形);
            if (!图形盒子实例.ok) return 图形盒子实例;
            引用矢量图形 = 图形盒子实例.value.获取笔画列表();
          }
          const 笔画列表: 矢量图形数据 = [];
          字形数据.strokes.forEach((x) => {
            if (x.feature === "reference") {
              const 源笔画 = 引用矢量图形[x.index];
              if (源笔画 === undefined) return; // 允许指标越界
              笔画列表.push(源笔画);
            } else {
              笔画列表.push(x);
            }
          });
          字形列表.push(
            new 部件(字符实例, 标签集合, 字形数据.compat, 笔画列表),
          );
        }
      }
      return ok(字形列表);
    } else {
      const 引用字形列表的列表: 字形[][] = [];
      for (const 部分名称 of 字形数据.operandList) {
        const 引用字符 = this.校验(部分名称)?.character;
        if (!引用字符) return default_err(`无法找到字符: ${部分名称}`);
        const 引用字形列表 = 字库.查询字形(引用字符);
        if (!引用字形列表) return default_err(`无法找到字符: ${部分名称}`);
        引用字形列表的列表.push(引用字形列表);
      }
      const 字形列表: 字形[] = [];
      // 0-0: G
      const 反向索引映射: Map<string, 源标签集合> = new Map();
      for (const 标签 of 字形数据.tags) {
        const 索引列表列表: number[][] = [];
        for (const 字形列表 of 引用字形列表的列表) {
          const 索引列表 = this.匹配标签(字形列表, 标签);
          索引列表列表.push(索引列表);
        }
        for (const 组合 of 排列组合(索引列表列表)) {
          const 索引组合 = 组合.map(String).join(",");
          if (!反向索引映射.has(索引组合))
            反向索引映射.set(索引组合, new Set([标签]));
          else 反向索引映射.get(索引组合)!.add(标签);
        }
      }
      for (const [索引组合, 标签集合] of 反向索引映射) {
        const 组合 = 索引组合.split(",").map(Number);
        const 部分列表: 字形[] = [];
        for (const [部分索引, 字形索引] of 组合.entries()) {
          部分列表.push(引用字形列表的列表[部分索引]![字形索引]!);
        }
        const 默认笔顺: 笔画块[] = 部分列表.map((_, index) => ({
          index,
          strokes: 0,
        }));
        // 接下来要分为复合体或拼接部件两种情况处理
        if (字形数据.type === "compound") {
          const 新字形 = new 复合体(
            字符实例,
            标签集合,
            字形数据.compat,
            字形数据.operator,
            部分列表,
            字形数据.order ?? 默认笔顺,
          );
          字形列表.push(新字形);
        } else {
          const 图形盒子列表: 图形盒子[] = [];
          for (const 字形 of 部分列表) {
            if (字形 instanceof 部件)
              图形盒子列表.push(图形盒子.从笔画列表构建(字形.矢量图形));
            else {
              // 尝试把复合体变成图形盒子
              const 如图形盒子 = 字库.递归渲染复合体(字形);
              if (!如图形盒子.ok) return 如图形盒子;
              图形盒子列表.push(如图形盒子.value);
            }
          }
          const 笔画列表 = 图形盒子
            .仿射合并({ ...字形数据, tags: [] }, 图形盒子列表)
            .获取笔画列表();
          字形列表.push(
            new 部件(字符实例, 字形数据.tags, 字形数据.compat, 笔画列表),
          );
        }
      }
      return ok(字形列表);
    }
  }

  校验自定义映射(自定义元素集合: Record<string, 自定义分析>) {
    const 自定义分析映射: 自定义分析映射 = new Map();
    const 自定义元素映射 = new Map<string, 自定义元素[]>();
    for (const [类别, 映射] of Object.entries(自定义元素集合)) {
      const 元素名称映射 = new Map<string, 自定义元素>();
      for (const [汉字, 元素名称列表] of Object.entries(映射)) {
        const 字符实例 = this.校验(汉字);
        if (!字符实例) continue;
        const 记录 =
          自定义分析映射.get(字符实例.character) ??
          new Map<string, 自定义元素[]>();
        const 元素列表: 自定义元素[] = [];
        for (const 元素名称 of 元素名称列表) {
          const 元素 =
            元素名称映射.get(元素名称) ?? new 自定义元素(类别, 元素名称);
          元素列表.push(元素);
          if (!元素名称映射.has(元素名称)) 元素名称映射.set(元素名称, 元素);
        }
        记录.set(类别, 元素列表);
        自定义分析映射.set(字符实例.character, 记录);
      }
      自定义元素映射.set(类别, [...元素名称映射.values()]);
    }
    return { 自定义分析映射, 自定义元素映射 };
  }

  校验词典(原始词典: 原始词典): 词典 {
    const result: 词典 = [];
    for (const { 词, ...rest } of 原始词典) {
      const 字符列表: 字符[] = [];
      let valid = true;
      for (const 字符 of [...词]) {
        const 字符实例 = this.校验(字符)?.character;
        if (字符实例) {
          字符列表.push(字符实例);
        } else {
          valid = false;
        }
      }
      if (valid) result.push({ 词: 字符列表, ...rest });
    }
    return result;
  }

  过滤词典(词典: 词典, 字集指示: 字集指示): 词典 {
    const 过滤函数 = 字集过滤查找表[字集指示]!;
    const result: 词典 = [];
    for (const 条目 of 词典) {
      let valid = true;
      for (const 汉字 of 条目.词) {
        const 汉字数据 = this.查询(汉字);
        if (!汉字数据) continue;
        if (!过滤函数(汉字数据.character, 汉字数据)) valid = false;
      }
      if (valid) result.push(条目);
    }
    return result;
  }

  获取汉字集合(词典: 词典): Set<字符> {
    const 字符集合 = new Set<字符>();
    for (const { 词 } of 词典) {
      for (const 汉字 of 词) {
        const 汉字数据 = this.查询(汉字);
        if (!汉字数据) continue;
        字符集合.add(汉字);
      }
    }
    return 字符集合;
  }
}

export { 原始字库 };

import type { 组装器, 组装配置 } from "./assembly.js";
import type { 部件分析器 } from "./component.js";
import type { 复合体分析器 } from "./compound.js";
import type { 拼音分析器, 拼音分析映射 } from "./pinyin.js";
import type { 字形分析配置 } from "./repertoire.js";
import type { 筛选器 } from "./selector.js";

interface 构造器<配置, 组件> {
  new (config: 配置): 组件;
  type: string;
}

type 部件分析构造器 = 构造器<字形分析配置, 部件分析器>;
type 复合体分析构造器 = 构造器<字形分析配置, 复合体分析器>;
type 拼音分析构造器 = 构造器<拼音分析映射, 拼音分析器>;
type 组装器构造器 = 构造器<组装配置, 组装器>;
type 筛选器构造器 = 构造器<undefined, 筛选器>;

/**
 * 注册表单例，管理各类组件的注册与创建
 */
class 注册表 {
  部件分析器映射: Map<string, 部件分析构造器> = new Map();
  复合体分析器映射: Map<string, 复合体分析构造器> = new Map();
  拼音分析器映射: Map<string, 拼音分析构造器> = new Map();
  组装器映射: Map<string, 组装器构造器> = new Map();
  筛选器映射: Map<string, 筛选器构造器> = new Map();

  创建部件分析器(名称: string, 配置: 字形分析配置): 部件分析器 | undefined {
    const 构造器 = this.部件分析器映射.get(名称);
    return 构造器 ? new 构造器(配置) : undefined;
  }

  注册部件分析器(部件分析器: 部件分析构造器) {
    this.部件分析器映射.set(部件分析器.type, 部件分析器);
  }

  创建复合体分析器(名称: string, 配置: 字形分析配置): 复合体分析器 | undefined {
    const 构造器 = this.复合体分析器映射.get(名称);
    return 构造器 ? new 构造器(配置) : undefined;
  }

  注册复合体分析器(复合体分析器: 复合体分析构造器) {
    this.复合体分析器映射.set(复合体分析器.type, 复合体分析器);
  }

  创建拼音分析器(名称: string, 配置: 拼音分析映射): 拼音分析器 | undefined {
    const 构造器 = this.拼音分析器映射.get(名称);
    return 构造器 ? new 构造器(配置) : undefined;
  }

  注册拼音分析器(拼音分析器: 拼音分析构造器) {
    this.拼音分析器映射.set(拼音分析器.type, 拼音分析器);
  }

  创建组装器(名称: string, 配置: 组装配置): 组装器 | undefined {
    const 构造器 = this.组装器映射.get(名称);
    return 构造器 ? new 构造器(配置) : undefined;
  }

  注册组装器(组装器: 组装器构造器) {
    this.组装器映射.set(组装器.type, 组装器);
  }

  注册筛选器(筛选器: 筛选器构造器) {
    this.筛选器映射.set(筛选器.type, 筛选器);
  }

  创建筛选器(名称: string): 筛选器 | undefined {
    const 构造器 = this.筛选器映射.get(名称);
    return 构造器 ? new 构造器(undefined) : undefined;
  }
}

let 注册表实例: 注册表 | undefined;

export function 获取注册表() {
  if (!注册表实例) {
    注册表实例 = new 注册表();
  }
  return 注册表实例;
}

export { 注册表 };

import { isEqual } from "lodash-es";
import { 图形盒子 } from "./affine.js";
import { type 分类器, 合并分类器 } from "./classifier.js";
import { 部件, 默认退化配置 } from "./component.js";
import { 复合体 } from "./compound.js";
import type { 分析配置, 条件, 退化配置 } from "./config.js";
import type { 复合体数据 } from "./data.js";
import { 二笔, type 元素, 笔画 } from "./element.js";
import type { 原始字库 } from "./primitive.js";
import { 获取注册表 } from "./registry.js";
import { type 筛选器, 默认筛选器列表 } from "./selector.js";
import { 字符 } from "./unicode.js";
import {
  ok,
  type Result,
  type 强类型决策,
  type 强类型决策空间,
  type 强类型安排,
  type 强类型安排描述,
} from "./utils.js";

export type 字形 = 部件 | 复合体;

export function 是部件(字形: 字形): 字形 is 部件 {
  return 字形 instanceof 部件;
}

export function 是复合体(字形: 字形): 字形 is 复合体 {
  return 字形 instanceof 复合体;
}

export type 字根 = 笔画 | 二笔 | 部件;

interface 基本部件分析 {
  类型: "部件";
  字根序列: 字根[];
  部件: 部件;
}

export type 带条件<T extends object> = T & {
  条件列表: 条件[];
};

export const 存在 = (x: 字根): 条件 => ({
  element: x.获取名称(),
  op: "不是" as const,
  value: null,
});

interface 基本复合体分析 {
  类型: "复合体";
  字根序列: 字根[];
  复合体: 复合体;
}

type 基本分析 = 基本部件分析 | 基本复合体分析;

interface 字形分析结果<
  部件分析 extends 基本部件分析 = 基本部件分析,
  复合体分析 extends 基本复合体分析 = 基本复合体分析,
> {
  分析结果: Map<字符, (部件分析 | 复合体分析)[]>;
  字根部件列表: 部件[];
}

interface 动态字形分析结果<
  部件分析 extends 基本部件分析 = 基本部件分析,
  复合体分析 extends 基本复合体分析 = 基本复合体分析,
> {
  分析结果: Map<字符, (优先表<部件分析> | 优先表<复合体分析>)[]>;
  字根部件列表: 部件[];
}

interface 字形分析基本配置 {
  分析配置: 分析配置;
  决策: 强类型决策;
  决策空间: 强类型决策空间;
  线性化决策: Map<元素, string>;
  自定义分析映射: Map<部件, (字符 | 笔画 | 二笔)[]>;
  动态自定义分析映射: Map<部件, (字符 | 笔画 | 二笔)[][]>;
  字形来源列表: string[];
}

interface 字形分析配置 {
  决策: 强类型决策;
  决策空间: 强类型决策空间;
  线性化决策: Map<元素, string>;
  字根决策: Map<字根, 强类型安排>;
  字根决策空间: Map<字根, 强类型安排描述[]>;
  可选字根: Set<字根>;
  分类器: 分类器; // 已经填充过默认值
  部件字根列表: 部件[];
  复合体字根映射: Map<复合体, 部件>;
  自定义分析映射: Map<部件, 字根[]>;
  动态自定义分析映射: Map<部件, 字根[][]>;
  退化配置: 退化配置;
  筛选器列表: [string, 筛选器][];
  强字根列表: 字根[];
  弱字根列表: 字根[];
}

export class 优先表<T extends object> {
  constructor(private 列表: 带条件<T>[]) {}

  [Symbol.iterator]() {
    return this.列表[Symbol.iterator]();
  }
}

type 内部带条件 = { 条件列表: 条件[]; 排除: 条件[]; array: object[] };

function 预处理优先表(列表: 带条件<object>[]): 内部带条件[] {
  return 列表.map((entry, i) => {
    const 排除: 条件[] = [];
    for (let j = 0; j < i; j++) {
      const 差集 = 列表[j]!.条件列表.filter(
        (c) => !entry.条件列表.some((e) => isEqual(c, e)),
      );
      if (差集.length === 1 && !排除.some((e) => isEqual(e, 差集[0]!))) {
        排除.push(差集[0]!);
      }
    }
    return { ...entry, 排除, array: [entry] };
  });
}

export function 贝叶斯推断<Ts extends object[], U extends object>(
  优先表列表: { [K in keyof Ts]: 带条件<Ts[K] & object>[] },
  reducer: (a: Ts) => U,
): 带条件<U>[] {
  const recurse = (l: 带条件<object>[][]): 内部带条件[] => {
    if (l.length === 1) return 预处理优先表(l[0]!);
    const 前一个表 = recurse(l.slice(0, -1));
    const 当前表 = 预处理优先表(l.at(-1)!);
    const 结果列表: 内部带条件[] = [];
    for (const 前一个项 of 前一个表) {
      for (const 当前项 of 当前表) {
        const 合并负 = [...前一个项.排除, ...当前项.排除];
        const 合并正 = [...前一个项.条件列表, ...当前项.条件列表];
        if (合并正.some((c) => 合并负.some((e) => isEqual(c, e)))) continue;
        const 扩充条件列表 = [...前一个项.条件列表];
        const 合并项: 内部带条件 = {
          array: [...前一个项.array, ...当前项.array],
          条件列表: 扩充条件列表,
          排除: 合并负,
        };
        if (蕴含(前一个项.条件列表, 当前项.条件列表)) {
          结果列表.push(合并项);
          break;
        } else {
          for (const 条件 of 当前项.条件列表) {
            if (!扩充条件列表.some((c) => isEqual(c, 条件))) {
              扩充条件列表.push(条件);
            }
          }
          结果列表.push(合并项);
        }
      }
    }
    return 结果列表;
  };
  const 结果列表 = recurse(优先表列表 as 带条件<object>[][]).map((x) => ({
    ...reducer(x.array as Ts),
    条件列表: x.条件列表,
  }));
  return 结果列表;
}

function 蕴含(已有列表: 条件[], 目标列表: 条件[]): boolean {
  for (const 目标 of 目标列表) {
    if (!已有列表.some((条件) => isEqual(条件, 目标))) {
      return false;
    }
  }
  return true;
}

class 字库 {
  private repertoire: Map<字符, 字形[]>;

  constructor(repertoire: Map<字符, 字形[]> = new Map()) {
    this.repertoire = repertoire;
  }

  *[Symbol.iterator](): Iterator<{ 字符: 字符; 字形列表: 字形[] }> {
    for (const [字符, 字形列表] of this.repertoire) {
      yield { 字符, 字形列表 };
    }
  }

  查询字形(character: 字符): 字形[] | undefined {
    return this.repertoire.get(character);
  }

  添加(character: 字符, 字形列表: 字形[]) {
    this.repertoire.set(character, 字形列表);
  }

  找到部件(key: string, 原始字库: 原始字库): 部件 | undefined {
    let 汉字字符串 = key,
      索引 = 0;
    if (key.includes("-")) {
      汉字字符串 = key.split("-")[0] ?? "";
      索引 = parseInt(key.split("-")[1] ?? "", 10);
    }
    const 字符 = 原始字库.校验(汉字字符串)?.character;
    if (!字符) return;
    const 字形列表 = (this.查询字形(字符) ?? []).filter(
      (x) => x instanceof 部件,
    ) as 部件[];
    return 字形列表[索引];
  }

  准备字形分析配置(
    分析配置: 分析配置,
    决策: 强类型决策,
    决策空间: 强类型决策空间,
    线性化决策: Map<元素, string>,
    自定义分析映射: Map<部件, (字符 | 笔画 | 二笔)[]>,
    动态自定义分析映射: Map<部件, (字符 | 笔画 | 二笔)[][]>,
  ): Result<字形分析配置, Error> {
    const 字根决策 = new Map<字根, 强类型安排>();
    const 字根决策空间 = new Map<字根, 强类型安排描述[]>();
    const 可选字根 = new Set<字根>();
    const 分类器 = 合并分类器(分析配置.classifier);
    const 全部元素 = new Set<元素>([...决策.keys(), ...决策空间.keys()]);
    const 部件字根列表: 部件[] = [];
    const 复合体字根映射: Map<复合体, 部件> = new Map();
    for (const 元素 of 全部元素) {
      const 安排 = 决策.get(元素);
      const 安排列表 = 决策空间.get(元素) ?? [];
      const 所有字根: 字根[] = [];
      if (元素 instanceof 笔画 || 元素 instanceof 二笔) {
        所有字根.push(元素);
      } else if (元素 instanceof 字符) {
        const 字形列表 = this.查询字形(元素) ?? [];
        for (const 字根字形 of 字形列表) {
          if (字根字形 instanceof 部件) {
            部件字根列表.push(字根字形);
            所有字根.push(字根字形);
          } else {
            const 图形盒子 = this.递归渲染复合体(字根字形);
            if (!图形盒子.ok) return 图形盒子;
            const 真部件 = new 部件(
              元素,
              字根字形.标签集合,
              字根字形.兼容,
              图形盒子.value.获取笔画列表(),
            );
            部件字根列表.push(真部件);
            复合体字根映射.set(字根字形, 真部件);
            所有字根.push(真部件);
          }
        }
      }
      for (const 字根 of 所有字根) {
        字根决策空间.set(字根, 安排列表);
        if (安排) 字根决策.set(字根, 安排);
        if (安排 === undefined || 安排列表?.some((x) => x.value == null)) {
          可选字根.add(字根);
        }
      }
    }
    const 全部字根 = [...字根决策空间.keys()];
    const 新自定义分析映射 = new Map<部件, 字根[]>();
    const 新动态自定义分析映射 = new Map<部件, 字根[][]>();
    for (const [部件实例, 元素列表] of 自定义分析映射) {
      const 字根列表: 字根[] = [];
      for (const 元素 of 元素列表) {
        if (元素 instanceof 笔画 || 元素 instanceof 二笔) 字根列表.push(元素);
        else {
          const 字根 = 全部字根.find(
            (x) => x instanceof 部件 && x.字符 === 元素,
          );
          if (字根) 字根列表.push(字根);
        }
      }
      新自定义分析映射.set(部件实例, 字根列表);
    }
    for (const [部件实例, 元素列表列表] of 动态自定义分析映射) {
      const 字根列表列表: 字根[][] = [];
      for (const 元素列表 of 元素列表列表) {
        const 字根列表: 字根[] = [];
        for (const 元素 of 元素列表) {
          if (元素 instanceof 笔画 || 元素 instanceof 二笔) 字根列表.push(元素);
          else {
            const 字根 = 全部字根.find(
              (x) => x instanceof 部件 && x.字符 === 元素,
            );
            if (字根) 字根列表.push(字根);
          }
        }
        字根列表列表.push(字根列表);
      }
      新动态自定义分析映射.set(部件实例, 字根列表列表);
    }
    const 字根名称映射 = new Map(
      [...字根决策.keys()].map((x) => [x.获取名称(), x] as const),
    );
    const 筛选器列表: [string, 筛选器][] = [];
    for (const name of 分析配置.selector ?? 默认筛选器列表) {
      const 筛选器 = 获取注册表().创建筛选器(name);
      if (筛选器) {
        筛选器列表.push([name, 筛选器]);
      }
    }
    const 强字根列表: 字根[] = [];
    for (const name of 分析配置.strong ?? []) {
      const 字根 = 字根名称映射.get(name);
      if (字根) 强字根列表.push(字根);
    }
    const 弱字根列表: 字根[] = [];
    for (const name of 分析配置.weak ?? []) {
      const 字根 = 字根名称映射.get(name);
      if (字根) 弱字根列表.push(字根);
    }
    return ok({
      决策,
      决策空间,
      线性化决策,
      退化配置: 分析配置.degenerator ?? 默认退化配置,
      筛选器列表,
      分类器,
      字根决策,
      字根决策空间,
      可选字根,
      部件字根列表,
      复合体字根映射,
      自定义分析映射: 新自定义分析映射,
      动态自定义分析映射: 新动态自定义分析映射,
      强字根列表,
      弱字根列表,
    });
  }

  /**
   * 确定需要分析的字符
   */
  获取待分析部件(汉字列表: Set<字符>) {
    const 待分析部件集合: Set<部件> = new Set();
    const recurse = (glyph: 字形) => {
      if (是部件(glyph)) 待分析部件集合.add(glyph);
      else {
        for (const 子字形 of glyph.部分列表) {
          recurse(子字形);
        }
      }
    };
    for (const 汉字 of 汉字列表) {
      const 字形列表 = this.查询字形(汉字) ?? [];
      for (const 字形 of 字形列表) {
        recurse(字形);
      }
    }
    return 待分析部件集合;
  }

  /**
   * 将复合体递归渲染为 SVG 图形
   *
   * @param 复合体 - 复合体
   * @param repertoire - 原始字符集
   *
   * @returns SVG 图形或错误
   */
  递归渲染复合体(复合体: 复合体): Result<图形盒子, Error> {
    const 图形盒子列表: 图形盒子[] = [];
    for (const 部分 of 复合体.部分列表) {
      if (部分 instanceof 部件) {
        const 盒子 = 图形盒子.从笔画列表构建(部分.矢量图形);
        图形盒子列表.push(盒子);
      } else {
        const rendered = this.递归渲染复合体(部分);
        if (!rendered.ok) return rendered;
        图形盒子列表.push(rendered.value);
      }
    }
    return ok(
      图形盒子.仿射合并(
        {
          type: "compound",
          operator: 复合体.结构描述字符,
          order: 复合体.笔顺,
        } as 复合体数据,
        图形盒子列表,
      ),
    );
  }

  准备分析(base: 字形分析基本配置, 汉字集合: Set<字符>) {
    const {
      分析配置,
      决策,
      决策空间,
      线性化决策,
      自定义分析映射,
      动态自定义分析映射,
    } = base;
    const 如配置 = this.准备字形分析配置(
      分析配置,
      决策,
      决策空间,
      线性化决策,
      自定义分析映射,
      动态自定义分析映射,
    );
    if (!如配置.ok) return 如配置;
    const 配置 = 如配置.value;
    const 待分析部件集合 = this.获取待分析部件(汉字集合);
    const 部件分析器 = 获取注册表().创建部件分析器(
      分析配置.component_analyzer || "默认",
      配置,
    )!;
    const 复合体分析器 = 获取注册表().创建复合体分析器(
      分析配置.compound_analyzer || "默认",
      配置,
    )!;
    return ok({
      待分析部件集合,
      部件分析器,
      复合体分析器,
      字根部件列表: 配置.部件字根列表,
      复合体字根映射: 配置.复合体字根映射,
    });
  }

  /**
   * 对整个字符集中的字符进行拆分
   *
   * @param repertoire - 字符集
   * @param config - 配置
   */
  分析(
    base: 字形分析基本配置,
    汉字集合: Set<字符>,
  ): Result<字形分析结果, Error> {
    const 分析配置或错误 = this.准备分析(base, 汉字集合);
    if (!分析配置或错误.ok) return 分析配置或错误;
    const 分析配置 = 分析配置或错误.value;
    const 部件分析结果 = new Map<部件, 基本部件分析>();
    for (const 部件 of 分析配置.待分析部件集合) {
      const 分析 = 分析配置.部件分析器.分析(部件);
      if (!分析.ok) return 分析;
      部件分析结果.set(部件, 分析.value);
    }
    // 对冰雪飞花，把从复合体转出的部件也分析一下
    // if (base.分析配置.component_analyzer === "冰雪飞花") {
    //   for (const [_, 部件] of 分析配置.复合体字根映射) {
    //     const 分析 = 分析配置.部件分析器.分析(部件);
    //     if (!分析.ok) return 分析;
    //     部件分析结果.set(部件, 分析.value);
    //   }
    // }
    分析配置.复合体分析器.部件分析结果 = 部件分析结果;
    const 分析结果 = new Map<字符, 基本分析[]>();
    for (const 字符 of 汉字集合) {
      const 结果列表: 基本分析[] = [];
      const 字形列表 = this.查询字形(字符) ?? [];
      for (const 字形 of 字形列表) {
        if (字形 instanceof 部件) {
          const 分析 = 部件分析结果.get(字形)!;
          结果列表.push(分析);
        } else {
          const 分析 = 分析配置.复合体分析器.分析(字形);
          if (!分析.ok) return 分析;
          结果列表.push(分析.value);
        }
      }
      分析结果.set(字符, 结果列表);
    }
    for (const [部件, 分析] of 部件分析结果) {
      if (!汉字集合.has(部件.字符)) {
        分析结果.set(部件.字符, (分析结果.get(部件.字符) ?? []).concat([分析]));
      }
    }
    return ok({
      分析结果,
      字根部件列表: 分析配置.字根部件列表,
    });
  }

  /**
   * 对整个字符集中的字符进行拆分
   *
   * @param repertoire - 字符集
   * @param config - 配置
   */
  动态分析(
    base: 字形分析基本配置,
    汉字集合: Set<字符>,
  ): Result<动态字形分析结果, Error> {
    const 分析配置或错误 = this.准备分析(base, 汉字集合);
    if (!分析配置或错误.ok) return 分析配置或错误;
    const 分析配置 = 分析配置或错误.value;
    const 动态部件分析结果 = new Map<部件, 优先表<基本部件分析>>();
    for (const 部件 of 分析配置.待分析部件集合) {
      const 分析 = 分析配置.部件分析器.动态分析(部件);
      if (!分析.ok) return 分析;
      动态部件分析结果.set(部件, 分析.value);
    }
    分析配置.复合体分析器.动态部件分析结果 = 动态部件分析结果;
    const 分析结果 = new Map<
      字符,
      (优先表<基本部件分析> | 优先表<基本复合体分析>)[]
    >();
    for (const 字符 of 汉字集合) {
      const 结果列表: (优先表<基本部件分析> | 优先表<基本复合体分析>)[] = [];
      const 字形列表 = this.查询字形(字符) ?? [];
      for (const 字形 of 字形列表) {
        if (字形 instanceof 部件) {
          const 分析 = 动态部件分析结果.get(字形)!;
          结果列表.push(分析);
        } else {
          const 分析 = 分析配置.复合体分析器.动态分析(字形);
          if (!分析.ok) return 分析;
          结果列表.push(分析.value);
        }
      }
      分析结果.set(字符, 结果列表);
    }
    return ok({
      分析结果,
      字根部件列表: 分析配置.字根部件列表,
    });
  }
}

export type {
  动态字形分析结果,
  基本分析,
  基本复合体分析,
  基本部件分析,
  字形分析结果,
  字形分析配置,
};
export { 字库 };

import type { 曲线关系 } from "./bezier.js";
import type { 部件 } from "./component.js";
import type { 字根 } from "./repertoire.js";
import { type 强类型安排, 是强类型归并 } from "./utils.js";

const 默认筛选器列表: string[] = [
  "结构完整",
  "根少优先",
  "能连不交",
  "能散不连",
  "全符笔顺",
  "取大优先",
];

interface 拆分字根信息 {
  字根: 字根;
  笔画索引: number[];
  笔画二进制表示: number;
}

type 拆分方式 = 拆分字根信息[];

interface 拆分环境 {
  部件图形: 部件;
  二进制字根映射: Map<number, 字根>;
  字根决策: Map<字根, 强类型安排>;
  强字根列表: 字根[];
  弱字根列表: 字根[];
}

interface 筛选器 {
  评价: (scheme: 拆分方式, environment: 拆分环境) => number[];
}

class 根少优先 implements 筛选器 {
  static readonly type = "根少优先";
  评价(scheme: 拆分方式) {
    return [scheme.length];
  }
}

/**
 * 规则：取大优先
 *
 * 让顺序靠前的字根尽量取到更多的笔画
 */
class 取大优先 implements 筛选器 {
  static readonly type = "取大优先";
  评价(scheme: 拆分方式) {
    return scheme.map((x) => -x.笔画索引.length);
  }
}

/**
 * 规则：倒序取大
 *
 * 让顺序靠后的字根尽量取到更多的笔画
 */
class 倒序取大 implements 筛选器 {
  static readonly type = "倒序取大";
  评价(scheme: 拆分方式) {
    const reversedScheme = [...scheme].reverse();
    return reversedScheme.map((x) => -x.笔画索引.length);
  }
}

/**
 * 规则：首末取大
 *
 * 让顺序首位和末位的字根尽量取到更多的笔画，其余次之
 */
class 首末取大 implements 筛选器 {
  static readonly type = "首末取大";
  评价(scheme: 拆分方式) {
    let rearrangedScheme = [...scheme];
    if (rearrangedScheme.length > 2) {
      const first = rearrangedScheme.shift()!;
      const last = rearrangedScheme.pop()!;
      rearrangedScheme = [first, last, ...rearrangedScheme];
    }
    return rearrangedScheme.map((x) => -x.笔画索引.length);
  }
}

/**
 * 规则：取小优先
 *
 * 让顺序靠前的字根尽量取到更少的笔画
 */
class 取小优先 implements 筛选器 {
  static readonly type = "取小优先";
  评价(scheme: 拆分方式) {
    return scheme.map((x) => x.笔画索引.length);
  }
}

/**
 * 规则：全符笔顺
 *
 * 各个字根中笔画的顺序连在一起是否与整个部件的笔顺相同，相同者优先
 * 该规则采集自三码郑码的文档
 *
 * @see https://www.yuque.com/smzm/zhengma/otb32d
 */
class 全符笔顺 implements 筛选器 {
  static readonly type = "全符笔顺";
  评价(scheme: 拆分方式) {
    const indices = scheme.flatMap((x) => x.笔画索引);
    const isSorted = indices.every((value, index) => value === index);
    return [Number(!isSorted)];
  }
}

/**
 * 规则：连续笔顺
 *
 * 字根是否由部件中连续的几个笔画构成，不符合此特点的字根数量少者优先。该规则采集自宇浩输入法的文档。
 *
 * @see https://shurufa.app/learn/division#符合笔顺
 */
class 连续笔顺 implements 筛选器 {
  static readonly type = "连续笔顺";
  评价(scheme: 拆分方式) {
    let unsorted = 0;
    // 如果一个字根不是由连续的笔画构成，那么称它是不连续的
    // 让不连续的字根数量少者优先
    for (const { 笔画索引 } of scheme) {
      const sortedIndices = [...笔画索引].sort((a, b) => a - b);
      const diff = (sortedIndices.at(-1) ?? 0) - (sortedIndices[0] ?? 0);
      if (sortedIndices.length !== diff + 1) {
        unsorted += 1;
      }
    }
    return [unsorted];
  }
}

/**
 * 规则：非形近根
 *
 * 尽量少使用被归并到其他字根的字根。该规则采集自三码郑码的文档
 *
 * @see https://www.yuque.com/smzm/zhengma/otb32d
 */
class 非形近根 implements 筛选器 {
  static readonly type = "非形近根";
  评价(scheme: 拆分方式, { 字根决策 }: 拆分环境) {
    let 形近根数量 = 0;
    for (const { 字根 } of scheme) {
      const value = 字根决策.get(字根);
      if (value && 是强类型归并(value)) {
        形近根数量 += 1;
      }
    }
    return [形近根数量];
  }
}

/**
 * 规则：强字根
 *
 * 尽量多使用特定的一些字根。该规则采集自郑码的文档
 */
class 多强字根 implements 筛选器 {
  static readonly type = "多强字根";
  评价(scheme: 拆分方式, { 强字根列表 }: 拆分环境) {
    const count = scheme.filter((x) => 强字根列表.includes(x.字根)).length;
    return [-count];
  }
}

/**
 * 规则：弱字根
 *
 * 尽量避免使用特定的一些字根
 */
class 少弱字根 implements 筛选器 {
  static readonly type = "少弱字根";
  评价(scheme: 拆分方式, { 弱字根列表 }: 拆分环境) {
    const count = scheme.filter((x) => 弱字根列表.includes(x.字根)).length;
    return [count];
  }
}

const 计算出现次数 = (
  relationType: 曲线关系["type"],
  avoidRelationType: 曲线关系["type"][],
  scheme: 拆分方式,
  component: 部件,
) => {
  let count = 0;
  for (const [i, { 笔画索引: bi }] of scheme.entries()) {
    for (const [j, { 笔画索引: bj }] of scheme.entries()) {
      if (j >= i) continue;
      let r = false;
      let a = false;
      for (const k of bi) {
        for (const l of bj) {
          const relations = component.查询拓扑关系(k, l);
          if (!relations) continue;
          r ||= relations.some((v) => v.type === relationType);
          a ||= relations.some((v) => avoidRelationType.includes(v.type));
        }
      }
      if (!a) count += Number(r);
    }
  }
  return count;
};

/**
 * 规则：能连不交
 *
 * 尽量让字根不交叉。该规则采集自五笔
 */
class 能连不交 implements 筛选器 {
  static readonly type = "能连不交";
  评价(scheme: 拆分方式, { 部件图形: component }: 拆分环境) {
    const crosses = 计算出现次数("交", [], scheme, component);
    return [crosses];
  }
}

/**
 * 规则：能散不连
 *
 * 尽量让字根不相连。该规则采集自五笔
 */
class 能散不连 implements 筛选器 {
  static readonly type = "能散不连";
  评价(scheme: 拆分方式, { 部件图形: component }: 拆分环境) {
    const connects = 计算出现次数("连", ["交"], scheme, component);
    return [connects];
  }
}

/**
 * 规则：同向笔画
 *
 * 尽量让方向相同的笔画包含在同一个字根里。该规则采集自五笔
 */
class 同向笔画 implements 筛选器 {
  static readonly type = "同向笔画";
  评价(scheme: 拆分方式, { 部件图形: component }: 拆分环境) {
    let totalCrosses = 0;
    for (const [i, { 笔画索引: bi }] of scheme.entries()) {
      for (const [j, { 笔画索引: bj }] of scheme.entries()) {
        if (j >= i) continue;
        let r = false;
        for (const k of bi) {
          for (const l of bj) {
            const oriented = component.具有同向笔画(k, l);
            r ||= oriented;
          }
        }
        totalCrosses += Number(r);
      }
    }
    return [totalCrosses];
  }
}

/**
 * 规则：结构完整
 *
 * 避免框类部件被拆散。该规则采集自宇浩输入法的文档
 *
 * @see https://shurufa.app/learn/division#结构完整
 */
class 结构完整 implements 筛选器 {
  static readonly type = "结构完整";
  评价(scheme: 拆分方式, { 二进制字根映射 }: 拆分环境) {
    const priorities = [
      "口",
      "囗",
      "冂",
      "\ue439" /* 见二 */,
      "匚",
      "凵",
      "\ue009" /* 假右角 */,
      "勹",
      "尸",
      "\ue407" /* 央三 */,
    ];
    let 破坏结构完整 = 0;
    for (const [二进制表示, 字根] of 二进制字根映射) {
      if (priorities.includes(字根.获取名称())) {
        if (
          !scheme.some(({ 笔画二进制表示 }) =>
            结构完整.contains(笔画二进制表示, 二进制表示),
          )
        ) {
          破坏结构完整 += 1;
        }
      }
    }
    return [破坏结构完整];
  }

  /**
   * @param b1 - 以二进制数表示的切片
   * @param b2 - 同上
   * @returns 第一个切片是否包含第二个切片
   */
  static contains(b1: number, b2: number) {
    return (b1 | b2) === b1;
  }
}

export type { 拆分方式, 拆分环境, 筛选器 };
export {
  倒序取大,
  全符笔顺,
  取大优先,
  取小优先,
  同向笔画,
  多强字根,
  少弱字根,
  根少优先,
  结构完整,
  能散不连,
  能连不交,
  连续笔顺,
  非形近根,
  首末取大,
  默认筛选器列表,
};

import type { 字集指示 } from "./config.js";
import type { 原始汉字数据 } from "./data.js";
import { default_err, ok, type Result } from "./utils.js";

export interface 区块 {
  name: string; // 简洁的英文名，如 "cjk", "cjk-a"
  label: string; // 中文全名，如 "中日韩统一表意文字"
  begin: number; // 起始 Unicode 码位（十进制）
  end: number; // 终止 Unicode 码位（十进制）
  count: number; // 实际收录数量
}

export const 区块列表: 区块[] = [
  // 统一汉字基本集与扩展
  {
    name: "cjk",
    label: "中日韩统一表意文字",
    begin: 0x4e00,
    end: 0x9fff,
    count: 20992,
  },
  {
    name: "cjk-a",
    label: "中日韩统一表意文字扩展A",
    begin: 0x3400,
    end: 0x4dbf,
    count: 6592,
  },
  {
    name: "cjk-b",
    label: "中日韩统一表意文字扩展B",
    begin: 0x20000,
    end: 0x2a6df,
    count: 42720,
  },
  {
    name: "cjk-c",
    label: "中日韩统一表意文字扩展C",
    begin: 0x2a700,
    end: 0x2b73f,
    count: 4160,
  },
  {
    name: "cjk-d",
    label: "中日韩统一表意文字扩展D",
    begin: 0x2b740,
    end: 0x2b81f,
    count: 222,
  },
  {
    name: "cjk-e",
    label: "中日韩统一表意文字扩展E",
    begin: 0x2b820,
    end: 0x2ceaf,
    count: 5774,
  },
  {
    name: "cjk-f",
    label: "中日韩统一表意文字扩展F",
    begin: 0x2ceb0,
    end: 0x2ebef,
    count: 7473,
  },
  {
    name: "cjk-g",
    label: "中日韩统一表意文字扩展G",
    begin: 0x30000,
    end: 0x3134f,
    count: 4939,
  },
  {
    name: "cjk-h",
    label: "中日韩统一表意文字扩展H",
    begin: 0x31350,
    end: 0x323af,
    count: 4192,
  },
  {
    name: "cjk-i",
    label: "中日韩统一表意文字扩展I",
    begin: 0x2ebf0,
    end: 0x2ee5f,
    count: 622,
  },
  {
    name: "cjk-j",
    label: "中日韩统一表意文字扩展J",
    begin: 0x323b0,
    end: 0x3347f,
    count: 4298,
  },

  // 部件
  {
    name: "radicals-sup",
    label: "中日韩部首补充",
    begin: 0x2e80,
    end: 0x2eff,
    count: 115,
  },
  { name: "kangxi", label: "康熙部首", begin: 0x2f00, end: 0x2fdf, count: 214 },
  {
    name: "strokes",
    label: "中日韩笔画",
    begin: 0x31c0,
    end: 0x31ef,
    count: 38,
  },

  // 兼容汉字
  {
    name: "compat",
    label: "中日韩兼容表意文字",
    begin: 0xf900,
    end: 0xfaff,
    count: 472,
  },
  {
    name: "compat-sup",
    label: "中日韩兼容表意文字补充",
    begin: 0x2f800,
    end: 0x2fa1f,
    count: 542,
  },

  // 古文字系统
  {
    name: "tangut",
    label: "西夏文",
    begin: 0x17000,
    end: 0x187ff,
    count: 6144,
  },
  {
    name: "tangut-comp",
    label: "西夏文字构件",
    begin: 0x18800,
    end: 0x18aff,
    count: 768,
  },
  {
    name: "tangut-sup",
    label: "西夏文补充",
    begin: 0x18d00,
    end: 0x18d7f,
    count: 31,
  },
  {
    name: "tangut-comp-sup",
    label: "西夏文字构件补充",
    begin: 0x18d80,
    end: 0x18dff,
    count: 115,
  },
  {
    name: "khitan-small",
    label: "契丹小字",
    begin: 0x18b00,
    end: 0x18cff,
    count: 470,
  },

  // 标点符号与排版字符
  {
    name: "punct",
    label: "中日韩符号和标点",
    begin: 0x3000,
    end: 0x303f,
    count: 64,
  },
  {
    name: "enclosed",
    label: "中日韩带圈字母和月份",
    begin: 0x3200,
    end: 0x32ff,
    count: 255,
  },
  {
    name: "enclosed-sup",
    label: "中日韩带圈文字补充",
    begin: 0x1f200,
    end: 0x1f2ff,
    count: 64,
  },
  {
    name: "ideo-symbols",
    label: "表意文字符号与标点",
    begin: 0x16fe0,
    end: 0x16fff,
    count: 7,
  },

  // 私用区
  { name: "pua", label: "私用区 (BMP)", begin: 0xe000, end: 0xf8ff, count: 0 },
  {
    name: "pua-plane15",
    label: "私用区 (Plane 15)",
    begin: 0xf0000,
    end: 0xffffd,
    count: 0,
  },
];

const 第十六平面起始位 = 0x100000;

export class 字符 {
  private static 自由码位 = 第十六平面起始位;
  private constructor(private readonly 码位: number) {}

  static 从码位创建(cp: number): Result<字符, Error> {
    if (!Number.isInteger(cp) || cp < 0 || cp > 0x10ffff) {
      return default_err(`不合法的 Unicode 码位: ${cp}`);
    }
    if (cp >= 0xd800 && cp <= 0xdfff) {
      return default_err(`不合法的 Unicode 码位: ${cp} (代理项)`);
    }
    const 新字符实例 = new 字符(cp);
    return ok(新字符实例);
  }

  获取名称(): string {
    return String.fromCodePoint(this.码位);
  }

  toNumber(): number {
    return this.码位;
  }

  十六进制(): string {
    return `U+${this.toNumber().toString(16).toUpperCase().padStart(4, "0")}`;
  }

  static 获取自由字符() {
    const 自由码位 = 字符.自由码位;
    字符.自由码位++;
    return 字符.从码位创建(自由码位);
  }

  static 重置() {
    字符.自由码位 = 第十六平面起始位;
  }

  区块() {
    for (const block of 区块列表) {
      if (this.码位 >= block.begin && this.码位 <= block.end) {
        return block.name;
      }
    }
    return "unknown";
  }

  是基本区汉字() {
    const block = this.区块();
    return block === "cjk";
  }

  是汉字() {
    const block = this.区块();
    return block.startsWith("cjk");
  }

  是汉字或兼容汉字() {
    const block = this.区块();
    return (
      block.startsWith("cjk") || block === "compat" || block === "compat-sup"
    );
  }

  是汉字补充() {
    const block = this.区块();
    return (
      block === "radicals-sup" ||
      block === "kangxi" ||
      block === "strokes" ||
      block === "compat" ||
      block === "compat-sup" ||
      block === "punct"
    );
  }

  是私用区() {
    const block = this.区块();
    return block === "pua" || block === "pua-plane15";
  }

  是用户私用区() {
    const block = this.区块();
    return block === "pua" && this.码位 >= 0xf000;
  }
}

export const 字集过滤查找表: Record<
  字集指示,
  (k: 字符, v: 原始汉字数据) => boolean
> = {
  minimal: (_, v) => v.gb2312 > 0 && v.tygf > 0,
  gb2312: (_, v) => v.gb2312 > 0,
  general: (_, v) => v.tygf > 0,
  basic: (k, v) => v.tygf > 0 || k.是基本区汉字(),
  extended: (k, v) => v.tygf > 0 || k.是汉字(),
  supplement: (k, v) => v.tygf > 0 || k.是汉字() || k.是汉字补充(),
  panlingual: (k, _) => !k.是私用区(),
  maximal: (_, __) => true,
};

export const 字集过滤选项 = [
  { label: "极简", value: "minimal" },
  { label: "GB2312", value: "gb2312" },
  { label: "通用", value: "general" },
  { label: "基本", value: "basic" },
  { label: "扩展", value: "extended" },
  { label: "补充", value: "supplement" },
  { label: "多语言", value: "panlingual" },
  { label: "全部", value: "maximal" },
];

import { isEqual, range } from "lodash-es";
import type { 动态组装条目, 组装条目 } from "./assembly.js";
import type { 分类器, 笔画名称 } from "./classifier.js";
import { 笔画表示方式 } from "./classifier.js";
import type { 部件 } from "./component.js";
import {
  type 元素位,
  type 兼容字形自定义,
  type 决策,
  type 决策空间,
  type 字形自定义,
  type 安排,
  type 安排描述,
  type 广义安排,
  type 广义码位,
  type 拼写运算,
  是变量,
  是归并,
  type 条件,
  type 生成配置,
  type 配置,
  type 非空安排,
} from "./config.js";
import {
  type 全等数据,
  type 原始汉字数据,
  type 向量,
  type 基本部件数据,
  type 复合体数据,
  type 字形描述,
  type 引用笔画数据,
  type 拼接部件数据,
  type 矢量笔画数据,
  type 结构描述字符,
  结构描述字符列表,
  type 绘制,
  type 衍生部件数据,
} from "./data.js";
import {
  二笔,
  type 元素,
  拼音元素,
  未知元素,
  笔画,
  结构符元素,
  type 自定义元素,
} from "./element.js";
import { 应用拼写运算, type 拼音分析映射 } from "./pinyin.js";
import type { 原始字库 } from "./primitive.js";
import type { 字库 } from "./repertoire.js";
import { 字符 } from "./unicode.js";

// Result 类型定义
export type Ok<T> = { ok: true; value: T; warning?: string };
export type Err<E> = { ok: false; error: E };
export type Result<T, E> = Ok<T> | Err<E>;
export function ok<T>(value: T, warning?: string): Result<T, never> {
  return { ok: true, value, warning };
}
export function err<E>(error: E): Result<never, E> {
  return { ok: false, error };
}
export function default_err(message: string): Result<never, Error> {
  return err(new Error(message));
}

// NTuple 类型定义
export type Tuple<T, N extends number> = N extends N
  ? number extends N
    ? T[]
    : _TupleOf<T, N, []>
  : never;

type _TupleOf<T, N extends number, R extends unknown[]> = R["length"] extends N
  ? R
  : _TupleOf<T, N, [T, ...R]>;

// 模拟函数
export const 模拟引用笔画 = (): 引用笔画数据 => ({
  feature: "reference",
  index: 0,
});

export const 模拟矢量笔画 = (
  名称: 笔画名称,
  起点: 向量 = [0, 0],
  旧绘制列表: 绘制[] = [],
): 矢量笔画数据 => {
  const 绘制类型列表 = 笔画表示方式[名称];
  return {
    feature: 名称,
    start: 起点,
    curveList: 绘制类型列表.map((command, index) => {
      if (旧绘制列表[index]?.command === command) {
        return 旧绘制列表[index]!;
      }
      switch (command) {
        case "a":
          return { command, parameterList: [20] };
        case "h":
        case "v":
          return { command, parameterList: [20] };
        default:
          return { command, parameterList: [10, 10, 20, 20, 30, 30] };
      }
    }),
  };
};

export const 模拟空基本部件 = (): 基本部件数据 => ({
  type: "basic_component",
  strokes: [],
});

export const 模拟基本部件 = (): 基本部件数据 => ({
  type: "basic_component",
  strokes: [模拟矢量笔画("横")],
});

export const 模拟衍生部件 = (): 衍生部件数据 => ({
  type: "derived_component",
  source: "一",
  strokes: [模拟引用笔画()],
});

export const 模拟拼接部件 = (): 拼接部件数据 => ({
  type: "spliced_component",
  operator: "⿰",
  operandList: ["一", "丨"],
});

export const 模拟全等 = (): 全等数据 => ({
  type: "identity",
  source: "一",
});

export const 模拟复合体 = (operator: 结构描述字符): 复合体数据 => ({
  type: "compound",
  operator,
  operandList: ["一", "一"],
});

export const 是基本或衍生部件 = (
  glyph: 字形描述,
): glyph is 基本部件数据 | 衍生部件数据 =>
  glyph.type === "basic_component" || glyph.type === "derived_component";

export const 创建原始汉字数据 = (
  unicode: number,
  glyphs: 字形描述[],
  name: string | null = null,
): 原始汉字数据 => ({
  unicode,
  tygf: 0,
  gb2312: 0,
  gf0014_id: null,
  gf3001_id: null,
  ambiguous: false,
  name,
  glyphs,
});

// 输入输出便利函数
interface 键位频率目标 {
  理想值: number;
  低于惩罚: number;
  高于惩罚: number;
}

export type 词典条目 = { 词: 字符[]; 拼音: string[]; 频率: number };
export type 原始词典条目 = Omit<词典条目, "词"> & { 词: string };
export type 词典 = 词典条目[];
export type 原始词典 = 原始词典条目[];
export type 频率映射 = Map<string, number>;
export type 键位分布目标 = Map<string, 键位频率目标>;
export type 当量映射 = Map<string, number>;

export const 可打印字符列表 = range(33, 127).map((x) =>
  String.fromCodePoint(x),
);

export function 读取表格(tsvText: string): string[][] {
  const lines = tsvText.trim().split("\n");
  const table: string[][] = lines.map((line) => line.split("\t"));
  return table;
}

export function 解析键位分布目标(tsv: string[][]): 键位分布目标 {
  const data: 键位分布目标 = new Map();
  for (const [char, ideal_s, lt_penalty_s, gt_penalty_s] of tsv) {
    if (
      char === undefined ||
      ideal_s === undefined ||
      lt_penalty_s === undefined ||
      gt_penalty_s === undefined
    )
      continue;
    const [ideal, lt_penalty, gt_penalty] = [
      ideal_s,
      lt_penalty_s,
      gt_penalty_s,
    ].map(Number) as [number, number, number];
    if (
      Number.isNaN(ideal) ||
      Number.isNaN(lt_penalty) ||
      Number.isNaN(gt_penalty)
    )
      continue;
    data.set(char, {
      理想值: ideal,
      低于惩罚: lt_penalty,
      高于惩罚: gt_penalty,
    });
  }
  return data;
}

export const 序列化键位频率目标 = (target: 键位分布目标): string[][] => {
  const result: string[][] = [];
  for (const [char, { 理想值, 低于惩罚, 高于惩罚 }] of target) {
    result.push([
      char,
      理想值.toString(),
      低于惩罚.toString(),
      高于惩罚.toString(),
    ]);
  }
  return result;
};

export function 解析当量映射(tsv: string[][]): 当量映射 {
  const data: 当量映射 = new Map();
  for (const [sequence, value_s] of tsv) {
    if (sequence === undefined || value_s === undefined) continue;
    const value = Number(value_s);
    if (Number.isNaN(value)) continue;
    data.set(sequence, value);
  }
  return data;
}

export const 序列化当量映射 = (mapping: 当量映射): string[][] => {
  const result: string[][] = [];
  for (const [char, value] of mapping) {
    result.push([char, value.toString()]);
  }
  return result;
};

export function 解析原始词典(tsv: string[][]): 原始词典 {
  const result: 原始词典条目[] = [];
  for (const [word, pinyin_s, frequency_s] of tsv) {
    if (
      word === undefined ||
      pinyin_s === undefined ||
      frequency_s === undefined
    )
      continue;
    const pinyin = pinyin_s.split(" ");
    const frequency = Number(frequency_s);
    if (Number.isNaN(frequency)) continue;
    result.push({ 词: word, 拼音: pinyin, 频率: frequency });
  }
  return result;
}

export function 序列化词典(词典: 原始词典): string[][] {
  const result: string[][] = [];
  for (const { 词, 拼音, 频率 } of 词典) {
    result.push([词, 拼音.join(" "), 频率.toString()]);
  }
  return result;
}

export function 解析笔画数据(tsv: string[][]) {
  const 笔画数据 = new Map<string, string>();
  for (const [char, strokes] of tsv) {
    if (char === undefined || strokes === undefined) continue;
    笔画数据.set(char, strokes);
  }
  return 笔画数据;
}

export function 解析自定义元素(tsv: string[][]): Record<string, string[]> {
  const result: Record<string, string[]> = {};
  for (const [key, values_s] of tsv) {
    if (key === undefined || values_s === undefined) continue;
    result[key] = values_s.split(" ");
  }
  return result;
}

export interface 码表条目 {
  词: string;
  编码: string;
}

export function 解析码表(tsv: string[][]): 码表条目[] {
  const result: 码表条目[] = [];
  for (const [word, code] of tsv) {
    if (word === undefined || code === undefined) continue;
    result.push({ 词: word, 编码: code });
  }
  return result;
}

export const 序列化 = (key?: 强类型元素位或编码) => {
  if (key === undefined) {
    return "ε";
  } else if (typeof key === "string") {
    return key;
  } else {
    return `${key.element.获取名称()}.${key.index}`;
  }
};

export const 总序列化 = (keys: (强类型元素位或编码 | undefined)[]) => {
  return keys.map(序列化).join(" ");
};

export const 反序列化 = (
  key: string,
  map: Map<string, 元素>,
): Result<强类型元素位或编码 | undefined, Error> => {
  if (key === "ε") {
    return ok(undefined);
  } else if (key.includes(".")) {
    const [element, index_s] = key.split(".");
    const index = Number(index_s);
    if (element === undefined || index_s === undefined || Number.isNaN(index)) {
      return default_err(`无法反序列化码位: ${key}`);
    }
    return ok({ element: map.get(element)!, index });
  } else {
    return ok(key);
  }
};

export const 计算拼音分析与元素映射 = (
  词典: 词典,
  拼写运算查找表: Map<string, 拼写运算>,
) => {
  const 音节集合 = new Set<string>();
  for (const { 拼音 } of 词典) {
    拼音.map((p) => 音节集合.add(p));
  }
  const 拼音元素映射: Map<string, 拼音元素[]> = new Map();
  const 拼音分析映射: 拼音分析映射 = new Map();
  for (const [类型, 拼写运算] of 拼写运算查找表) {
    const 元素名称映射 = new Map<string, 拼音元素>();
    for (const 音节 of 音节集合) {
      const 元素名称 = 应用拼写运算(拼写运算, 音节);
      const 元素 = 元素名称映射.get(元素名称) ?? new 拼音元素(类型, 元素名称);
      if (!元素名称映射.has(元素名称)) 元素名称映射.set(元素名称, 元素);
      const 拼音分析 = 拼音分析映射.get(音节) ?? new Map<string, 拼音元素>();
      拼音分析.set(类型, 元素);
      拼音分析映射.set(音节, 拼音分析);
    }
    const 元素列表 = [...元素名称映射.values()].sort((a, b) =>
      a.获取名称().localeCompare(b.获取名称()),
    );
    拼音元素映射.set(类型, 元素列表);
  }
  return { 拼音元素映射, 拼音分析映射 };
};

export const 计算全部合法元素与元素映射 = (
  字符列表: 字符[],
  分类器: 分类器,
  拼音元素映射: Map<string, 拼音元素[]>,
  自定义元素映射: Map<string, 自定义元素[]>,
) => {
  const 全部笔画类别 = [...new Set(Object.values(分类器))].sort(
    (a, b) => a - b,
  );
  const 笔画列表: 笔画[] = [];
  for (const n of 全部笔画类别) {
    笔画列表.push(笔画.创建(n));
  }
  const 二笔列表: 二笔[] = [];
  for (const n1 of 全部笔画类别) {
    for (const n2 of [0, ...全部笔画类别]) {
      二笔列表.push(二笔.创建(n1, n2));
    }
  }
  const 结构符元素列表 = 结构描述字符列表.map((x) => new 结构符元素(x));
  const 名称映射: Map<string, 元素> = new Map();
  const 普通元素: 元素[] = [
    ...字符列表,
    ...笔画列表,
    ...二笔列表,
    ...结构符元素列表,
  ];
  for (const 元素 of 普通元素) {
    名称映射.set(元素.获取名称(), 元素);
  }
  for (const [_, 元素列表] of 拼音元素映射) {
    for (const 元素 of 元素列表) 名称映射.set(元素.获取名称(), 元素);
  }
  for (const [_, 元素列表] of 自定义元素映射) {
    for (const 元素 of 元素列表) 名称映射.set(元素.获取名称(), 元素);
  }
  return {
    字符列表,
    笔画列表,
    二笔列表,
    结构符元素列表,
    拼音元素映射,
    自定义元素映射,
    名称映射,
  };
};

export const 合并字符串 = <T extends 强类型广义引用>(keys: T[]) => {
  return keys.every((x) => typeof x === "string") ? keys.join("") : keys;
};

export function 构建强类型决策与决策空间(
  决策: 决策,
  决策空间: 决策空间,
  元素名称映射: Map<string, 元素>,
) {
  const 强类型决策 = new Map<元素, 强类型非空安排>();
  const 强类型决策空间 = new Map<元素, 强类型安排描述[]>();
  const 当前元素名称映射 = new Map<string, 元素>(元素名称映射);
  for (const 元素名称 of Object.keys(决策).concat(Object.keys(决策空间))) {
    const 元素 = 元素名称映射.get(元素名称);
    if (!元素) {
      当前元素名称映射.set(元素名称, new 未知元素(元素名称));
    }
  }
  for (const [元素名称, 安排] of Object.entries(决策)) {
    const 元素 = 当前元素名称映射.get(元素名称)!;
    const 强安排 = 恢复安排(安排, 当前元素名称映射) as 强类型安排 | undefined;
    if (!强安排) continue;
    强类型决策.set(元素, 强安排);
  }
  for (const [元素名称, 安排描述列表] of Object.entries(决策空间)) {
    const 元素 = 当前元素名称映射.get(元素名称)!;
    const 强安排描述列表: 强类型安排描述[] = [];
    for (const { value, score, condition } of 安排描述列表) {
      const 强安排 = 恢复安排(value, 当前元素名称映射);
      if (强安排 === undefined) continue;
      if (condition) {
        const new_condition: 强类型条件[] = [];
        let valid = true;
        for (const { element, op, value } of condition) {
          const 依赖元素 = 当前元素名称映射.get(element);
          if (!依赖元素) {
            valid = false;
            break;
          }
          const 依赖安排 = 恢复安排(value, 当前元素名称映射) as
            | 强类型安排
            | undefined;
          if (依赖安排 === undefined) {
            valid = false;
            break;
          }
          new_condition.push({ element: 依赖元素, op, value: 依赖安排 });
        }
        if (valid) {
          强安排描述列表.push({
            value: 强安排,
            score,
            condition: new_condition,
          });
        }
      } else {
        强安排描述列表.push({ value: 强安排, score });
      }
    }
    强类型决策空间.set(元素, 强安排描述列表);
  }
  return { 决策: 强类型决策, 决策空间: 强类型决策空间 };
}

export function 构建强类型自定义分析(
  字库: 字库,
  原始字库: 原始字库,
  名称映射: Map<string, 元素>,
  自定义分析: Record<string, string[]>,
  动态自定义拆分: Record<string, string[][]>,
) {
  const 自定义分析映射: Map<部件, (字符 | 笔画 | 二笔)[]> = new Map();
  const 动态自定义分析映射: Map<部件, (字符 | 笔画 | 二笔)[][]> = new Map();
  for (const [key, value] of Object.entries(自定义分析)) {
    const 部件实例 = 字库.找到部件(key, 原始字库);
    if (!部件实例) continue;
    const 字根列表: (字符 | 笔画 | 二笔)[] = [];
    for (const 字根名称 of value) {
      const 字根 = 名称映射.get(字根名称);
      if (字根 instanceof 笔画 || 字根 instanceof 二笔 || 字根 instanceof 字符)
        字根列表.push(字根);
    }
    自定义分析映射.set(部件实例, 字根列表);
  }
  for (const [key, value] of Object.entries(动态自定义拆分)) {
    const 部件实例 = 字库.找到部件(key, 原始字库);
    if (!部件实例) continue;
    const 字根列表列表: (字符 | 笔画 | 二笔)[][] = [];
    for (const 字根名称列表 of value) {
      const 字根列表: (字符 | 笔画 | 二笔)[] = [];
      for (const 字根名称 of 字根名称列表) {
        const 字根 = 名称映射.get(字根名称);
        if (
          字根 instanceof 笔画 ||
          字根 instanceof 二笔 ||
          字根 instanceof 字符
        )
          字根列表.push(字根);
      }
      字根列表列表.push(字根列表);
    }
    动态自定义分析映射.set(部件实例, 字根列表列表);
  }
  return { 自定义分析映射, 动态自定义分析映射 };
}

export function 序列化安排(安排: 强类型广义安排): 广义安排 {
  if (安排 === null) return null;
  if (typeof 安排 === "string") return 安排;
  if (Array.isArray(安排)) {
    return 安排.map((x) => {
      if (typeof x === "string" || x === null) return x;
      if (是强类型变量(x)) return x;
      return { element: x.element.获取名称(), index: x.index };
    });
  }
  return { element: 安排.element.获取名称() };
}

export function 序列化强类型决策(决策: 强类型决策): 决策 {
  const 基本决策: 决策 = {};
  for (const [元素, 安排] of 决策) {
    基本决策[元素.获取名称()] = 序列化安排(安排) as 非空安排;
  }
  return 基本决策;
}

export function 序列化强类型决策空间(决策空间: 强类型决策空间): 决策空间 {
  const 基本决策空间: 决策空间 = {};
  for (const [元素, 安排描述列表] of 决策空间) {
    基本决策空间[元素.获取名称()] = 安排描述列表.map(
      ({ value, score, condition }) => {
        const 基本描述: 安排描述 = { value: 序列化安排(value), score };
        if (condition) {
          基本描述.condition = condition.map(({ element, op, value }) => ({
            element: element.获取名称(),
            op,
            value: 序列化安排(value) as 安排,
          }));
        }
        return 基本描述;
      },
    );
  }
  return 基本决策空间;
}

export class 决策图 {
  private readonly 安排表: Map<元素, 强类型非空安排>;
  private readonly 归并入边: Map<元素, 元素[]>;
  private readonly 第一位引用入边: Map<元素, 元素[]>;

  constructor(mapping: 强类型决策) {
    this.安排表 = new Map(mapping);
    this.归并入边 = new Map();
    this.第一位引用入边 = new Map();
    for (const [elem, 安排] of mapping) {
      if (是强类型归并(安排)) {
        const list = this.归并入边.get(安排.element) ?? [];
        list.push(elem);
        this.归并入边.set(安排.element, list);
      } else if (Array.isArray(安排)) {
        const 已添加 = new Set<元素>();
        // 只考虑第一位是引用的情况，因为其他位即使是引用也不影响第一码的分组和排序
        for (const part of 安排.slice(0, 1)) {
          if (typeof part === "string") continue;
          const ref = part.element;
          if (!已添加.has(ref)) {
            已添加.add(ref);
            const list = this.第一位引用入边.get(ref) ?? [];
            list.push(elem);
            this.第一位引用入边.set(ref, list);
          }
        }
      }
    }
  }

  线性化(): Result<Map<元素, string>, Error> {
    const cache = new Map<元素, string>();
    const visiting = new Set<元素>();

    const evaluate = (key: 元素): Result<string, Error> => {
      if (cache.has(key)) return ok(cache.get(key)!);
      if (visiting.has(key)) return default_err(`循环依赖: ${key.获取名称()}`);
      visiting.add(key);
      const 安排 = this.安排表.get(key);
      if (安排 === undefined)
        return default_err(`决策中不存在键: ${key.获取名称()}`);
      let result: Result<string, Error>;
      if (typeof 安排 === "string") {
        result = ok(安排);
      } else if (是强类型归并(安排)) {
        result = evaluate(安排.element);
      } else {
        const parts: string[] = [];
        for (const part of 安排) {
          if (typeof part === "string") {
            parts.push(part);
          } else if (part === null || 是强类型变量(part)) {
            parts.push("a");
          } else {
            const sub = evaluate(part.element);
            if (!sub.ok) return sub;
            parts.push(sub.value[part.index] ?? "");
          }
        }
        result = ok(parts.join(""));
      }
      visiting.delete(key);
      if (result.ok) cache.set(key, result.value);
      return result;
    };

    const output = new Map<元素, string>();
    for (const key of this.安排表.keys()) {
      const v = evaluate(key);
      if (!v.ok) return v;
      output.set(key, v.value);
    }
    return ok(output);
  }

  获取被归并元素(name: 元素): { from: 元素; to: 元素 }[] {
    const result: { from: 元素; to: 元素 }[] = [];
    const visit = (parent: 元素, node: 元素) => {
      result.push({ from: node, to: parent });
      for (const child of this.归并入边.get(node) ?? []) {
        visit(node, child);
      }
    };
    for (const child of this.归并入边.get(name) ?? []) {
      visit(name, child);
    }
    return result;
  }

  // 按第一码分组，组内按引用关系 DFS 排序（被引用者在前，引用者紧随其后）
  生成翻转决策(
    字母表: string,
  ): Result<Map<string, { 元素: 元素; 安排: 强类型非归并安排 }[]>, Error> {
    const 翻转决策 = new Map<
      string,
      { 元素: 元素; 安排: 强类型非归并安排 }[]
    >();
    for (const 字母 of [...字母表]) 翻转决策.set(字母, []);
    const 收集元素 = ({
      元素,
      安排,
    }: {
      元素: 元素;
      安排: string | 强类型元素位或编码[];
    }) => {
      const 结果 = [{ 元素, 安排 }];
      for (const 子元素 of this.第一位引用入边.get(元素) ?? []) {
        const 子安排 = this.安排表.get(子元素);
        if (typeof 子安排 === "string") {
          结果.push(...收集元素({ 元素: 子元素, 安排: 子安排 }));
        } else if (Array.isArray(子安排)) {
          结果.push(...收集元素({ 元素: 子元素, 安排: 子安排 }));
        }
      }
      return 结果;
    };
    for (const [元素, 安排] of this.安排表) {
      if (是强类型归并(安排)) continue;
      let 第一位字母: string | undefined;
      if (typeof 安排 === "string") {
        第一位字母 = 安排.slice(0, 1);
      } else if (Array.isArray(安排)) {
        const 第一位 = 安排[0];
        if (typeof 第一位 === "string") {
          第一位字母 = 第一位;
        }
      }
      if (第一位字母) {
        const group = 翻转决策.get(第一位字母);
        if (group) {
          group.push(...收集元素({ 元素, 安排 }));
        }
      }
    }
    return ok(翻转决策);
  }
}

export function 计算当前或潜在长度(
  决策: 强类型决策,
  决策空间: 强类型决策空间,
): Result<Map<元素, number>, Error> {
  const 增广决策: Map<元素, 强类型非空安排> = new Map(决策);
  for (const [key, 安排列表] of 决策空间) {
    if (!增广决策.has(key)) {
      const v = 安排列表.find((x) => x.value !== null);
      if (v === undefined)
        return default_err(`元素 ${key.获取名称()} 在决策空间中没有非空安排`);
      const value = v.value;
      if (value === null)
        return default_err(`元素 ${key.获取名称()} 在决策空间中没有非空安排`);
      if (是强类型归并(value)) 增广决策.set(key, value);
      else {
        增广决策.set(key, [...value].map((_) => "a").join(""));
      }
    }
  }
  const 线性化 = new 决策图(增广决策).线性化();
  if (!线性化.ok) return 线性化;
  return ok(new Map([...线性化.value].map(([k, v]) => [k, v.length])));
}

export type 强类型元素位或编码 = string | { element: 元素; index: number };

export const 下转换 = (c: 强类型元素位或编码) => {
  return typeof c === "string"
    ? c
    : { element: c.element.获取名称(), index: c.index };
};

export type 强类型广义引用 = 强类型元素位或编码 | null | { variable: string };

export type 强类型安排 = 强类型非空安排 | null;

export type 强类型非空安排 = string | 强类型元素位或编码[] | { element: 元素 };

export type 强类型广义安排 =
  | string
  | 强类型广义引用[]
  | { element: 元素 }
  | null;

export type 强类型非归并安排 = string | 强类型元素位或编码[];

export type 强类型决策 = Map<元素, 强类型非空安排>;

export type 强类型决策空间 = Map<元素, 强类型安排描述[]>;

export const 是强类型归并 = (a: 强类型广义安排): a is { element: 元素 } => {
  return typeof a === "object" && a !== null && "element" in a;
};

export const 是强类型变量 = (a: 强类型广义引用): a is { variable: string } => {
  return typeof a === "object" && a !== null && "variable" in a;
};

export function 恢复安排(
  安排: 广义安排,
  映射: Map<string, 元素>,
): 强类型广义安排 | undefined {
  if (安排 === null) return null;
  if (typeof 安排 === "string") return 安排;
  if (Array.isArray(安排)) {
    const ret: 强类型广义引用[] = [];
    for (const x of 安排) {
      if (typeof x === "string" || x === null) ret.push(x);
      else if (是变量(x)) ret.push(x);
      else {
        const 元素 = 映射.get(x.element);
        if (!元素) return undefined;
        ret.push({ element: 元素, index: x.index });
      }
    }
    return ret;
  }
  const 元素 = 映射.get(安排.element);
  if (!元素) return undefined;
  return { element: 元素 };
}

export interface 强类型安排描述 {
  value: 强类型广义安排;
  score: number;
  condition?: 强类型条件[];
}

export interface 强类型条件 {
  element: 元素;
  op: "是" | "不是";
  value: 强类型安排;
}

export const 识别符 = (词: 字符[], 拼音来源列表: string[][]) => {
  const 拼音列表 = 拼音来源列表.map((list) => list.join(" "));
  return `${词.map((c) => c.获取名称()).join("")}-${拼音列表.join(",")}`;
};

export type 自定义分析 = Record<string, string[]>;

export type 自定义分析映射 = Map<字符, Map<string, 自定义元素[]>>;

export const 排列组合 = <T>(array: T[][]): T[][] => {
  if (array.length === 0) return [[]];
  const [first, ...rest] = array;
  const restCombinations = 排列组合(rest);
  const combinations: T[][] = [];
  for (const item of first!) {
    for (const combination of restCombinations) {
      combinations.push([item, ...combination]);
    }
  }
  return combinations;
};

export const 添加优先简码 = <T extends 组装条目 | 动态组装条目>(
  entries: T[],
  优先简码映射: Map<string, number>,
) => {
  const result = entries.map((entry) => {
    const hash = 识别符(entry.词, entry.拼音来源列表);
    const level = 优先简码映射.get(hash);
    const { 拼音来源列表, ...rest } = entry;
    const value: Omit<T, "拼音来源列表"> & { 简码长度?: number } = rest;
    if (level !== undefined) value.简码长度 = level;
    return value;
  });
  return result;
};

export const 是源标签 = (tag: string): tag is 源标签 => /^[A-Z].*$/.test(tag);

export const 所有源标签 = [
  "G",
  "H",
  "T",
  "J",
  "K",
  "N",
  "V",
  "M",
  "S",
  "B",
  "U",
] as 源标签[];

export type 源标签 = string & { __brand: "source" };

export type 源标签集合 = Set<源标签>;

export const 标准化自定义 = (字形自定义: 兼容字形自定义) => {
  const 标准字形自定义: 字形自定义 = {};
  for (const [char, value] of Object.entries(字形自定义)) {
    if (Array.isArray(value)) {
      标准字形自定义[char] = value;
    } else {
      标准字形自定义[char] = [value];
    }
  }
  return 标准字形自定义;
};

export const 生成 = (config: 配置): 生成配置 => {
  const mapping = config.form.mapping;
  const mapping_space = config.form.mapping_space ?? {};
  const variables = config.form.mapping_variables ?? {};
  const generators = config.form.mapping_generators ?? [];

  const space: 决策空间 = structuredClone(mapping_space);

  // Step 1: 合并初始决策
  // Every element in mapping must have an entry in space
  for (const name of Object.keys(mapping)) {
    if (!(name in space)) space[name] = [];
  }
  // Each element's current mapping value must appear in its space list
  for (const [name, arrangements] of Object.entries(space)) {
    const current: 广义安排 = mapping[name] ?? null;
    if (!arrangements.some((a) => isEqual(a.value, current))) {
      arrangements.unshift({ value: current, score: 0.0 });
    }
  }

  // Step 2: 应用生成器
  for (const { regex, value } of generators) {
    const 模式 = new RegExp(regex, "u");
    for (const [元素名称, 安排列表] of Object.entries(space)) {
      if (!模式.test(元素名称)) continue;
      const 安排描述 = structuredClone(value);
      const 生成器安排 = 安排描述.value;
      if (Array.isArray(生成器安排)) {
        // For each existing Basic/Advanced arrangement, synthesize a new one using the template
        const 合成安排列表: 广义码位[][] = [];
        for (const 安排 of 安排列表) {
          const ev = 安排.value;
          if (typeof ev !== "string" && !Array.isArray(ev)) continue;
          const 约化安排: 广义码位[] = typeof ev === "string" ? [...ev] : ev;
          let valid = true;
          const combined: 广义码位[] = [];
          for (const [i, tpl] of 生成器安排.entries()) {
            const cur = 约化安排[i];
            if (cur === undefined) {
              valid = false;
              break;
            }
            // Variable placeholders may only substitute ASCII (string) keys
            if (typeof cur !== "string" && 是变量(tpl)) {
              valid = false;
              break;
            }
            // null in template means placeholder: keep existing value
            combined.push(tpl === null ? cur : tpl);
          }
          if (!valid) continue;
          if (!合成安排列表.some((v) => isEqual(v, combined)))
            合成安排列表.push(combined);
        }
        for (const value of 合成安排列表) {
          安排列表.push({ ...安排描述, value });
        }
      } else {
        安排列表.push(安排描述);
      }
    }
  }

  // Step 3: 展开变量 — replace Variable placeholders with all possible concrete values
  for (const 安排列表 of Object.values(space)) {
    const 队列 = [...安排列表];
    安排列表.length = 0;
    while (队列.length > 0) {
      const item = 队列.shift()!;
      const value = item.value;
      let expanded = false;
      if (Array.isArray(value)) {
        for (const [i, key] of value.entries()) {
          if (是变量(key)) {
            for (const varValue of variables[key.variable]?.keys ?? []) {
              const newKeys = [...value];
              newKeys[i] = varValue;
              队列.push({ ...item, value: newKeys });
            }
            expanded = true;
            break;
          }
        }
      }
      if (!expanded) 安排列表.push(item);
    }
  }

  // Step 4: 补充存在性条件 — arrangements referencing other elements require those elements to be non-null
  for (const 安排列表 of Object.values(space)) {
    for (const 安排 of 安排列表) {
      const referenced = new Set<string>();
      const value = 安排.value;
      if (是归并(value)) {
        referenced.add(value.element);
      } else if (Array.isArray(value)) {
        for (const key of value) {
          if (
            typeof key === "object" &&
            key !== null &&
            "element" in key &&
            "index" in key
          )
            referenced.add((key as 元素位).element);
        }
      }
      if (referenced.size === 0) continue;
      const newConditions: 条件[] = [...referenced].map((element) => ({
        element,
        op: "不是" as const,
        value: null,
      }));
      if (安排.condition) 安排.condition.push(...newConditions);
      else 安排.condition = newConditions;
    }
  }

  return { ...config, generated_mapping_space: space };
};

