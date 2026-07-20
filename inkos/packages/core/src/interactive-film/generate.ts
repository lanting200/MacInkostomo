import { chatCompletion, type LLMClient } from "../llm/provider.js";
import { StoryGraphSchema, type StoryGraph } from "./graph-schema.js";

const SYSTEM_PROMPT = `你是互动影游编剧。根据用户的故事前提，生成一个小而完整的可玩分支图。
严格只输出 JSON，结构如下：
{"schemaVersion":1,"projectId":"","title":"","variables":[{"name":"","type":"flag|counter|relationship|item","default":0,"desc":""}],"nodes":[{"id":"","title":"","type":"start|normal|branch|ending","sceneDesc":"","dialogue":[{"speaker":"","text":"","emotion":""}],"choices":[{"id":"","text":"","targetNodeId":"","condition":{"var":"","op":">=","value":0},"effects":[{"var":"","op":"add","value":1}]}]}],"endings":[{"id":"","nodeId":"","title":"","type":"good|bad|neutral|secret","description":""}]}
要求：恰好 1 个 type=start 节点；至少 2 个 branch 节点；至少 2 个差异化 ending；每条路径都能到达某个 ending；condition/effects 可省略；不要输出 JSON 以外的任何文字。`;

export function extractJson(text: string): unknown {
  const fenced = text.match(/```(?:json)?\s*([\s\S]*?)```/);
  const body = fenced ? fenced[1] : text;
  const start = body.indexOf("{");
  const end = body.lastIndexOf("}");
  if (start === -1 || end === -1 || end <= start) {
    throw new Error("LLM 未返回可解析的 JSON 对象");
  }
  return JSON.parse(body.slice(start, end + 1));
}

export function buildStoryGraphFromLLMText(text: string, projectId: string): StoryGraph {
  const parsed = extractJson(text) as Record<string, unknown>;
  const graph = StoryGraphSchema.parse({ ...parsed, projectId });
  if (graph.nodes.length === 0) {
    throw new Error("Invalid story graph: nodes array must not be empty");
  }
  return graph;
}

export interface GenerateStoryGraphInput {
  readonly projectId: string;
  readonly title: string;
  readonly premise: string;
}

export async function generateStoryGraph(
  client: LLMClient,
  model: string,
  input: GenerateStoryGraphInput,
  options?: { readonly maxTokens?: number },
): Promise<StoryGraph> {
  const res = await chatCompletion(client, model, [
    { role: "system", content: SYSTEM_PROMPT },
    { role: "user", content: `标题：${input.title}\n前提：${input.premise}` },
  ], { temperature: 0.5, maxTokens: options?.maxTokens ?? 8000 });
  return buildStoryGraphFromLLMText(res.content, input.projectId);
}
