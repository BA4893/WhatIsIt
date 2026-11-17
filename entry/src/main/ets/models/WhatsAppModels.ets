/**
 * WhatsApp data models for the redesigned shell. The shell works with sample
 * content before a device is linked and replaces it with live data from the
 * existing CdpBridge when a WhatsApp engine/backend is available.
 */
export class ChatItem {
  id: string = '';
  name: string = '';
  preview: string = '';
  time: string = '';
  unread: number = 0;
  muted: boolean = false;
  pinned: boolean = false;
  isGroup: boolean = false;
  isChannel: boolean = false;
  online: boolean = false;
  typing: boolean = false;
  avatarUrl: string = '';
}

export class MessageItem {
  id: string = '';
  chatId: string = '';
  text: string = '';
  time: string = '';
  out: boolean = false;
  status: string = '';
  sender: string = '';
  mediaType: string = '';
  mediaUrl: string = '';
  mediaName: string = '';
}

export class StatusItem {
  id: string = '';
  name: string = '';
  time: string = '';
  text: string = '';
  viewed: boolean = false;
  color: string = '#25D366';
}

export class ChannelItem {
  id: string = '';
  name: string = '';
  description: string = '';
  followers: number = 0;
  unread: number = 0;
}

export class CallItem {
  id: string = '';
  name: string = '';
  video: boolean = false;
  incoming: boolean = true;
  missed: boolean = false;
  time: string = '';
}

export class CommunityItem {
  id: string = '';
  name: string = '';
  description: string = '';
  members: number = 0;
  unread: number = 0;
  joined: boolean = false;
}
