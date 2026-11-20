import { supabase } from "./supabase";

function getExtension(file: File): string {
  // Try to derive from name first
  const nameParts = file.name.split(".");
  if (nameParts.length > 1) {
    return nameParts[nameParts.length - 1].toLowerCase();
  }
  // Fall back to mime type
  if (file.type.includes("webm")) return "webm";
  if (file.type.includes("ogg")) return "ogg";
  if (file.type.includes("mp4")) return "mp4";
  if (file.type.includes("wav")) return "wav";
  if (file.type.includes("jpeg") || file.type.includes("jpg")) return "jpg";
  if (file.type.includes("png")) return "png";
  if (file.type.includes("gif")) return "gif";
  if (file.type.includes("webp")) return "webp";
  return "bin";
}

export async function uploadMedia(
  file: File,
  elderlyProfileId: string,
  mediaType: "photo" | "question_audio" | "answer_audio",
  userId: string
): Promise<{ assetId: string }> {
  const assetId = crypto.randomUUID();
  const ext = getExtension(file);
  const storagePath = `${elderlyProfileId}/${assetId}.${ext}`;

  const { error: uploadError } = await supabase.storage
    .from("kincare-media")
    .upload(storagePath, file, { upsert: false });

  if (uploadError) {
    throw new Error(`Storage upload failed: ${uploadError.message}`);
  }

  const { error: dbError } = await supabase.from("media_assets").insert({
    id: assetId,
    elderly_profile_id: elderlyProfileId,
    uploaded_by_caregiver_id: userId,
    storage_bucket: "kincare-media",
    storage_path: storagePath,
    media_type: mediaType,
    mime_type: file.type || "application/octet-stream",
  });

  if (dbError) {
    // Best-effort: try to clean up the orphaned file
    await supabase.storage.from("kincare-media").remove([storagePath]);
    throw new Error(`media_assets insert failed: ${dbError.message}`);
  }

  return { assetId };
}

export async function getSignedUrl(storagePath: string): Promise<string> {
  const { data, error } = await supabase.storage
    .from("kincare-media")
    .createSignedUrl(storagePath, 3600);

  if (error || !data?.signedUrl) {
    throw new Error(`Failed to create signed URL: ${error?.message ?? "unknown"}`);
  }
  return data.signedUrl;
}

export async function deleteMediaAsset(
  assetId: string,
  storagePath: string
): Promise<void> {
  // Delete from storage first (non-fatal if the file is already gone)
  await supabase.storage.from("kincare-media").remove([storagePath]);

  const { error } = await supabase
    .from("media_assets")
    .delete()
    .eq("id", assetId);

  if (error) {
    throw new Error(`Failed to delete media_assets row: ${error.message}`);
  }
}
